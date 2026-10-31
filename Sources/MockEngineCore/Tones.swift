import AVFoundation
import Foundation
import MESCore

/// Synthetic audio for the mock: deterministic tones, noise and silence, and reading what clients send.
enum Tones {
    /// A seeded generator (SplitMix64), so the same seed gives the same samples.
    struct Random {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// −1…1
        mutating func unit() -> Float { Float(Double(next() >> 11) / Double(1 << 52)) * 2 - 1 }
    }

    /// A stable 64-bit hash of text (FNV-1a), for pitches and colours that follow a prompt.
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    static func frames(_ seconds: Double, rate: Int) -> Int { max(0, Int((seconds * Double(rate)).rounded())) }

    /// A sine at `hz` with a short fade in and out, so bursts don't click.
    static func tone(_ hz: Double, seconds: Double, rate: Int, level: Float = 0.3, vibrato: Double = 0) -> [Float] {
        let n = frames(seconds, rate: rate), fade = min(n / 2, rate / 100)
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let env = Float(min(1, Double(min(i, n - 1 - i)) / Double(max(1, fade))))
            return level * env * Float(sin(2 * .pi * hz * t + vibrato * sin(2 * .pi * 5 * t)))
        }
    }

    static func silence(_ seconds: Double, rate: Int) -> [Float] { [Float](repeating: 0, count: frames(seconds, rate: rate)) }

    /// Seeded noise, low-passed by `smoothing` (0 = white), with an envelope.
    static func noise(seconds: Double, rate: Int, seed: UInt64, level: Float = 0.25, smoothing: Float = 0.6) -> [Float] {
        var r = Random(seed)
        var last: Float = 0
        let n = frames(seconds, rate: rate)
        return (0..<n).map { i in
            last = smoothing * last + (1 - smoothing) * r.unit()
            let env = Float(sin(Double.pi * Double(i) / Double(max(1, n))))
            return level * env * last
        }
    }

    /// Interleaves mono samples into `channels`, as 16-bit integers.
    static func int16(_ mono: [Float], channels: Int, pan: Float = 0) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(mono.count * channels)
        for s in mono {
            for c in 0..<channels {
                let gain: Float = channels == 2 ? (c == 0 ? 1 - max(0, pan) : 1 + min(0, pan)) : 1
                out.append(Int16(max(-1, min(1, s * gain)) * 32767))
            }
        }
        return out
    }

    /// Samples in a stream's encoding (Base §6): little-endian 16-bit integers or 32-bit floats, interleaved.
    static func pcm(_ mono: [Float], channels: Int, encoding: StreamEncoding) -> Data {
        var data = Data(capacity: mono.count * channels * encoding.sampleBytes)
        for s in mono {
            for _ in 0..<channels {
                switch encoding {
                case .pcmS16LE: withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { data.append(contentsOf: $0) }
                case .pcmF32LE: withUnsafeBytes(of: max(-1, min(1, s)).bitPattern.littleEndian) { data.append(contentsOf: $0) }
                }
            }
        }
        return data
    }

    static func writeWAV(_ mono: [Float], rate: Int, channels: Int, to url: URL, pan: Float = 0) throws -> WAVFile {
        let wav = WAVFile(sampleRate: rate, channels: channels, samples: int16(mono, channels: channels, pan: pan))
        try wav.data.write(to: url)
        return wav
    }

    /// An audio input as mono floats at its own rate, with what conversion it took: WAV, FLAC, MP3 and AAC, through
    /// AVFoundation. `downmixed` when it had more than one channel.
    static func read(_ url: URL) throws -> (samples: [Float], rate: Int, downmixed: Bool) {
        if let data = try? Data(contentsOf: url), let wav = try? WAVFile(data), !wav.floatSamples.isEmpty || wav.pcm.isEmpty {
            return (downmix(wav.floatSamples, channels: wav.channels), wav.sampleRate, wav.channels > 1)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw MESError(.inputInvalid, "The mock couldn't decode the audio: \(error.localizedDescription)")
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MESError(.inputInvalid, "The audio is empty.")
        }
        try file.read(into: buffer)
        let channels = Int(format.channelCount), n = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: n)
        if let data = buffer.floatChannelData {
            for c in 0..<channels { for i in 0..<n { mono[i] += data[c][i] / Float(channels) } }
        }
        return (mono, Int(format.sampleRate), channels > 1)
    }

    static func downmix(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        return stride(from: 0, to: interleaved.count - channels + 1, by: channels).map { i in
            (0..<channels).reduce(Float(0)) { $0 + interleaved[i + $1] } / Float(channels)
        }
    }

    /// Linear resampling: fine for a mock, never for a model (Audio §1.3 asks for band-limited resampling).
    static func resample(_ samples: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !samples.isEmpty else { return samples }
        let n = Int((Double(samples.count) * Double(to) / Double(from)).rounded())
        return (0..<n).map { i in
            let x = Double(i) * Double(from) / Double(to), j = Int(x), f = Float(x - Double(j))
            let a = samples[min(j, samples.count - 1)], b = samples[min(j + 1, samples.count - 1)]
            return a + (b - a) * f
        }
    }

    /// Stretches or squeezes to exactly `count` samples.
    static func fit(_ samples: [Float], count: Int) -> [Float] {
        guard count != samples.count, !samples.isEmpty, count > 0 else { return count == 0 ? [] : samples }
        return resample(samples, from: samples.count, to: count)
    }
}
