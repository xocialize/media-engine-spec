import Foundation

/// RIFF/WAVE, the Audio profile's one MUST output format (Audio §1.1): writing PCM the kit streamed (Base §10.1), and
/// reading it back in the mock and the conformance suite. Integer PCM (format 1) and IEEE float (format 3) only.
public struct WAVFile: Sendable, Equatable {
    public enum SampleFormat: Sendable, Equatable { case int, float }
    public var sampleRate: Int
    public var channels: Int
    public var bitsPerSample: Int
    public var format: SampleFormat
    /// Interleaved little-endian samples, without the header.
    public var pcm: Data

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int, format: SampleFormat = .int, pcm: Data) {
        self.sampleRate = sampleRate; self.channels = channels; self.bitsPerSample = bitsPerSample
        self.format = format; self.pcm = pcm
    }

    /// 16-bit integer samples, interleaved.
    public init(sampleRate: Int, channels: Int, samples: [Int16]) {
        var data = Data(capacity: samples.count * 2)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        self.init(sampleRate: sampleRate, channels: channels, bitsPerSample: 16, pcm: data)
    }

    /// The format a stream encoding's samples are written in (Base §10.1: `pcm_s16le` as 16-bit integer WAV,
    /// `pcm_f32le` as 32-bit float WAV), so the file's samples equal the chunks'.
    public init(stream: StreamPlan, pcm: Data) {
        self.init(sampleRate: stream.sampleRate, channels: stream.channels, bitsPerSample: stream.encoding.sampleBytes * 8,
                  format: stream.encoding == .pcmF32LE ? .float : .int, pcm: pcm)
    }

    public var frameBytes: Int { channels * bitsPerSample / 8 }
    public var frames: Int { frameBytes > 0 ? pcm.count / frameBytes : 0 }
    public var durationSeconds: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }

    /// The file's bytes: a 44-byte header (`fmt ` and `data` chunks), then the samples.
    public var data: Data {
        var out = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(format == .float ? 3 : 1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * frameBytes)); u16(UInt16(frameBytes)); u16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }

    public enum ParseError: Error, Sendable { case notWAV, unsupported(String) }

    /// Reads a WAV file: the `fmt ` and `data` chunks, skipping any others (`LIST`, `fact`). WAVE_FORMAT_EXTENSIBLE is
    /// read by its sub-format.
    public init(_ file: Data) throws {
        let bytes = [UInt8](file)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { throw ParseError.notWAV }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var i = 12
        var fmt: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var pcm: Data?
        while i + 8 <= bytes.count {
            let id = String(decoding: bytes[i..<(i + 4)], as: UTF8.self), size = u32(i + 4), body = i + 8
            guard body + size <= bytes.count || id == "data" else { throw ParseError.notWAV }
            if id == "fmt ", size >= 16 {
                var tag = u16(body)
                if tag == 0xFFFE, size >= 40 { tag = u16(body + 24) }
                fmt = (tag, u16(body + 2), u32(body + 4), u16(body + 14))
            } else if id == "data" {
                pcm = Data(bytes[body..<min(bytes.count, body + size)])
            }
            i = body + size + (size & 1)
        }
        guard let fmt, let pcm else { throw ParseError.notWAV }
        guard fmt.tag == 1 || fmt.tag == 3 else { throw ParseError.unsupported("WAV format tag \(fmt.tag)") }
        self.init(sampleRate: fmt.rate, channels: fmt.channels, bitsPerSample: fmt.bits, format: fmt.tag == 3 ? .float : .int, pcm: pcm)
    }

    /// The samples as floats in −1…1, interleaved.
    public var floatSamples: [Float] {
        let raw = [UInt8](pcm)
        switch (format, bitsPerSample) {
        case (.int, 16):
            return stride(from: 0, to: raw.count - 1, by: 2).map { Float(Int16(bitPattern: UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8)) / 32768 }
        case (.int, 24):
            return stride(from: 0, to: raw.count - 2, by: 3).map {
                let v = Int32(raw[$0]) | Int32(raw[$0 + 1]) << 8 | Int32(Int8(bitPattern: raw[$0 + 2])) << 16
                return Float(v) / 8_388_608
            }
        case (.int, 32):
            return stride(from: 0, to: raw.count - 3, by: 4).map {
                Float(Int32(bitPattern: UInt32(raw[$0]) | UInt32(raw[$0 + 1]) << 8 | UInt32(raw[$0 + 2]) << 16 | UInt32(raw[$0 + 3]) << 24)) / 2_147_483_648
            }
        case (.float, 32):
            return stride(from: 0, to: raw.count - 3, by: 4).map {
                Float(bitPattern: UInt32(raw[$0]) | UInt32(raw[$0 + 1]) << 8 | UInt32(raw[$0 + 2]) << 16 | UInt32(raw[$0 + 3]) << 24)
            }
        default:
            return []
        }
    }

    /// Root-mean-square level of frames `from..<to` across channels, 0…1.
    public func rms(from: Int, to: Int) -> Double {
        let s = floatSamples
        let lo = max(0, from * channels), hi = min(s.count, to * channels)
        guard hi > lo else { return 0 }
        var sum = 0.0
        for i in lo..<hi { sum += Double(s[i]) * Double(s[i]) }
        return (sum / Double(hi - lo)).squareRoot()
    }
}
