import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A video clip in memory: 8-bit BGRA frames at a constant rate, an optional interleaved float audio track, and the
/// file's comment and copyright items. The mock video engine makes and reads these, and the conformance suite reads
/// engines' outputs with them.
public struct Clip: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Double
    /// BGRA, `width × height × 4` bytes each.
    public var frames: [[UInt8]]
    /// Interleaved samples, `channels` per frame; nil for a silent clip.
    public var audio: [Float]?
    public var sampleRate: Int
    public var channels: Int
    /// The comment item (Video §1.9: the AI-content disclosure goes here).
    public var comment: String?
    /// The copyright item (Base §10.2 rule 2: the licence goes here).
    public var copyright: String?

    public init(width: Int, height: Int, fps: Double, frames: [[UInt8]], audio: [Float]? = nil, sampleRate: Int = 48_000,
                channels: Int = 2, comment: String? = nil, copyright: String? = nil) {
        self.width = width; self.height = height; self.fps = fps; self.frames = frames; self.audio = audio
        self.sampleRate = sampleRate; self.channels = channels; self.comment = comment; self.copyright = copyright
    }

    public var durationSeconds: Double { Double(frames.count) / fps }
    public var audioSeconds: Double? { audio.map { Double($0.count / max(1, channels)) / Double(sampleRate) } }
}

/// What a clip's file says about it, read without keeping its frames.
public struct ClipFacts: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var frames: Int
    public var durationSeconds: Double
    /// The video codec's four-character code (`avc1`, `hvc1`).
    public var codec: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var audioSeconds: Double?
    public var comment: String?
    public var copyright: String?
    public var hasAudio: Bool { sampleRate != nil }
}

public enum Clips {
    public enum Codec: String, Sendable { case h264, hevc }

    public enum Failure: Error, CustomStringConvertible {
        case noVideoTrack(URL), write(String), read(String)
        public var description: String {
            switch self {
            case .noVideoTrack(let url): "\(url.lastPathComponent) has no video track"
            case .write(let s): "couldn't write the clip: \(s)"
            case .read(let s): "couldn't read the clip: \(s)"
            }
        }
    }

    // MARK: - Writing

    /// Writes `clip` as MP4 (or QuickTime) with H.264 or HEVC video and, when it has audio, AAC; the comment and
    /// copyright items go into the file's metadata.
    public static func write(_ clip: Clip, to url: URL, codec: Codec = .h264, fileType: AVFileType = .mp4) async throws {
        try? FileManager.default.removeItem(at: url)
        // MP4 is written as M4V, Apple's MP4 (Video §1.1: `video/mp4`): macOS 26's writer leaves the iTunes items, the
        // comment `©cmt` among them, out of a `.mp4` and keeps them in a `.m4v` (AB-A-0244).
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType == .mp4 ? .m4v : fileType)
        writer.metadata = metadata(clip, quickTime: fileType == .mov)
        let bitRate = max(2_000_000, Int(Double(clip.width * clip.height) * clip.fps * 2))
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: clip.width, AVVideoHeightKey: clip.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate, AVVideoAllowFrameReorderingKey: false,
                                              AVVideoMaxKeyFrameIntervalKey: 8],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: clip.width, kCVPixelBufferHeightKey as String: clip.height,
        ])
        guard writer.canAdd(video) else { throw Failure.write("the video input") }
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if let samples = clip.audio, !samples.isEmpty {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = clip.channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: clip.sampleRate, AVNumberOfChannelsKey: clip.channels,
                AVEncoderBitRateKey: clip.channels == 1 ? 96_000 : 192_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.write("the audio input") }
            writer.add(input)
            audioInput = input
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(clip.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * clip.channels),
                mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * clip.channels), mChannelsPerFrame: UInt32(clip.channels),
                mBitsPerChannel: 32, mReserved: 0)
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
        }

        guard writer.startWriting() else { throw Failure.write(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        // Both inputs are fed from their own queues: the writer interleaves, and a single loop feeding one input at a
        // time can wait forever for the other.
        let timescale = Int32((clip.fps * 1000).rounded())
        let frames = clip.frames, width = clip.width, height = clip.height
        let failed = LockedFlag()
        let pixels = Box(adaptor), session = Box(writer)
        // A writer that has failed (an encoder it couldn't get, a disk error) invalidates its pool: stop feeding it.
        let writing = { @Sendable in session.value.status == .writing && !failed.value }
        var feeds: [(Box<AVAssetWriterInput>, @Sendable (Int) -> Bool)] = [(Box(video), { index in
            guard index < frames.count else { return false }
            guard writing() else { failed.set(); return false }
            // A buffer of its own per frame, not the adaptor's pool, which crashed under parallel load (its pool can go
            // invalid while the writer still reports .writing).
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard let buffer else { failed.set(); return false }
            fill(buffer, frames[index], width: width, height: height)
            if !pixels.value.append(buffer, withPresentationTime: CMTime(value: Int64(index) * 1000, timescale: timescale)) {
                failed.set(); return false
            }
            return true
        })]
        if let audioInput, let audioFormat, let samples = clip.audio {
            let channels = clip.channels, rate = clip.sampleRate, per = 1024, input = Box(audioInput), format = Box(audioFormat)
            feeds.append((input, { index in
                let start = index * per, total = samples.count / channels
                guard start < total else { return false }
                guard writing() else { failed.set(); return false }
                let count = min(per, total - start)
                guard let buffer = sampleBuffer(Array(samples[(start * channels)..<((start + count) * channels)]), frames: count,
                                                at: start, rate: rate, format: format.value) else { failed.set(); return false }
                if !input.value.append(buffer) { failed.set(); return false }
                return true
            }))
        }
        await feed(feeds)
        await writer.finishWriting()
        if writer.status != .completed || failed.value {
            throw Failure.write(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    /// Feeds each input from a queue of its own until its `next` returns false, marking it finished, and returns when
    /// all are.
    static func feed(_ feeds: [(Box<AVAssetWriterInput>, @Sendable (Int) -> Bool)]) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (i, (input, next)) in feeds.enumerated() {
                group.enter()
                let state = Counter()
                input.value.requestMediaDataWhenReady(on: DispatchQueue(label: "mes.mock.clips.\(i)")) {
                    while input.value.isReadyForMoreMediaData {
                        if state.finished { return }
                        if !next(state.index) {
                            state.finished = true
                            input.value.markAsFinished()
                            group.leave()
                            return
                        }
                        state.index += 1
                    }
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
    }

    /// Hands AVFoundation objects to the queues that feed them; each is used from one queue at a time.
    struct Box<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

    final class Counter: @unchecked Sendable { var index = 0; var finished = false }
    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    static func fill(_ buffer: CVPixelBuffer, _ frame: [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        frame.withUnsafeBytes { src in
            for y in 0..<height {
                memcpy(base + y * stride, src.baseAddress! + y * width * 4, width * 4)
            }
        }
    }

    static func sampleBuffer(_ samples: [Float], frames: Int, at start: Int, rate: Int, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                            offsetIntoDestination: 0, dataLength: bytes) }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: Int64(start), timescale: Int32(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }

    static func metadata(_ clip: Clip, quickTime: Bool) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func item(_ identifier: AVMetadataIdentifier, _ value: String) {
            let i = AVMutableMetadataItem()
            i.identifier = identifier
            i.value = value as NSString
            i.extendedLanguageTag = "und"
            items.append(i)
        }
        if let comment = clip.comment { item(quickTime ? .quickTimeMetadataComment : .iTunesMetadataUserComment, comment) }
        if let copyright = clip.copyright { item(quickTime ? .quickTimeMetadataCopyright : .iTunesMetadataCopyright, copyright) }
        return items
    }

    // MARK: - Reading

    /// Reads a clip: its frames as BGRA (unless `frames` is false, when `frames` is empty and only counted in the
    /// facts), its audio as interleaved floats at the track's own rate and channels, and its comment and copyright.
    public static func read(_ url: URL, frames wantFrames: Bool = true) async throws -> (Clip, ClipFacts) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack(url) }
        let (natural, transform, nominal, formats) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                          .formatDescriptions)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let width = Int(abs(rect.width).rounded()), height = Int(abs(rect.height).rounded())
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: wantFrames
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        var audioOutput: AVAssetReaderTrackOutput?
        var sampleRate: Int?, channels: Int?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            if let f = audioFormats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                sampleRate = Int(asbd.mSampleRate); channels = Int(asbd.mChannelsPerFrame)
            }
            let o = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(o)
            audioOutput = o
        }
        guard reader.startReading() else { throw Failure.read(reader.error?.localizedDescription ?? "startReading") }
        // copyNextSampleBuffer blocks, and on macOS 26 the reader needs a cooperative thread to make progress: read on
        // a queue of our own, or a few clips read at once on a small machine take every cooperative thread and wait for
        // ever (GitHub's three-core runner did, AB-A-0244).
        let (frames, count, times, audio) = try await Self.blocking { [video = Box(output), audioOutput = audioOutput.map(Box.init), reader = Box(reader)] in
            let output = video.value
            var frames: [[UInt8]] = []
            var count = 0
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sample)
                guard n > 0 else { continue }
                count += wantFrames ? 1 : n
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                if wantFrames, let image = CMSampleBufferGetImageBuffer(sample) { frames.append(bytes(image, width: width, height: height)) }
            }
            var audio: [Float]?
            if let audioOutput = audioOutput?.value {
                var samples: [Float] = []
                while let sample = audioOutput.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var chunk = [Float](repeating: 0, count: length / 4)
                    chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                    samples += chunk
                }
                audio = samples
            }
            if reader.value.status == .failed { throw Failure.read(reader.value.error?.localizedDescription ?? "reading failed") }
            return (frames, count, times, audio)
        }
        var sortedTimes = times
        // The rate: from the frame times (exact for a constant rate), else the track's nominal one, which AVFoundation
        // estimates from the track's duration and can be off by a fraction of a frame.
        var fps = Double(nominal)
        sortedTimes.sort()
        if sortedTimes.count > 1, sortedTimes.last! > sortedTimes.first! {
            fps = Double(sortedTimes.count - 1) / (sortedTimes.last! - sortedTimes.first!)
        }
        fps = (fps * 1000).rounded() / 1000
        var comment: String?, copyright: String?
        for item in try await asset.load(.metadata) {
            guard let id = item.identifier, let value = try? await item.load(.stringValue) else { continue }
            switch id {
            case .iTunesMetadataUserComment, .quickTimeMetadataComment, .quickTimeUserDataComment: comment = value
            case .iTunesMetadataCopyright, .quickTimeMetadataCopyright, .quickTimeUserDataCopyright, .commonIdentifierCopyrights:
                copyright = copyright ?? value
            default: break
            }
        }
        let ch = channels ?? 2
        let clip = Clip(width: width, height: height, fps: fps, frames: frames, audio: audio, sampleRate: sampleRate ?? 48_000,
                        channels: ch, comment: comment, copyright: copyright)
        let facts = ClipFacts(width: width, height: height, fps: fps, frames: count, durationSeconds: fps > 0 ? Double(count) / fps : 0,
                              codec: codec, sampleRate: sampleRate, channels: channels,
                              audioSeconds: audio.flatMap { a in sampleRate.map { Double(a.count / max(1, ch)) / Double($0) } },
                              comment: comment, copyright: copyright)
        return (clip, facts)
    }

    /// Runs `body`, which blocks, on a queue of its own rather than a cooperative thread.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "mes.mock.clips.read").async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// A clip's facts, counting its frames without decoding them.
    public static func facts(_ url: URL) async throws -> ClipFacts { try await read(url, frames: false).1 }

    static func bytes(_ image: CVImageBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        guard let base = CVPixelBufferGetBaseAddress(image) else { return out }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let w = min(width, CVPixelBufferGetWidth(image)), h = min(height, CVPixelBufferGetHeight(image))
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h { memcpy(dst.baseAddress! + y * width * 4, base + y * stride, w * 4) }
        }
        return out
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Frames

    /// The mean absolute difference between two BGRA frames of one size, per channel, 0–255 (alpha ignored).
    public static func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
        }
        return Double(sum) / Double(a.count / 4 * 3)
    }

    /// A BGRA frame scaled to `width × height` (CoreGraphics, high-quality interpolation), or aspect-filled and
    /// centre-cropped when `fill` is set.
    public static func scaled(_ frame: [UInt8], width: Int, height: Int, to newWidth: Int, _ newHeight: Int, fill: Bool = false) -> [UInt8] {
        guard let image = cgImage(frame, width: width, height: height) else { return [UInt8](repeating: 0, count: newWidth * newHeight * 4) }
        return draw(image, width: newWidth, height: newHeight, fill: fill)
    }

    /// An image drawn into a BGRA frame, scaled to fit exactly, or aspect-filled and centre-cropped.
    static func draw(_ image: CGImage, width: Int, height: Int, fill: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.interpolationQuality = .high
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            if fill {
                let s = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
                let w = Double(image.width) * s, h = Double(image.height) * s
                rect = CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
            }
            ctx.draw(image, in: rect)
        }
        return out
    }

    static func cgImage(_ frame: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(frame) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// An image file (PNG, JPEG, …) as a BGRA frame of `width × height`, aspect-filled and centre-cropped (Video §3.1).
    public static func frame(contentsOf url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.read("\(url.lastPathComponent) isn't an image")
        }
        return draw(image, width: width, height: height, fill: true)
    }

    /// A BGRA frame encoded as JPEG (for previews) or PNG.
    public static func encode(_ frame: [UInt8], width: Int, height: Int, type: UTType = .jpeg, quality: Double = 0.7) -> Data? {
        guard let image = cgImage(frame, width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A blend of two BGRA frames, `t` of the way from `a` to `b`.
    public static func blend(_ a: [UInt8], _ b: [UInt8], _ t: Double) -> [UInt8] {
        guard a.count == b.count else { return a }
        let w = max(0, min(1, t))
        return zip(a, b).map { UInt8((Double($0) * (1 - w) + Double($1) * w).rounded()) }
    }

    /// A synthetic BGRA frame: a background coloured by `color`, with a light bar that crosses the frame as `t` goes
    /// from 0 to 1, so motion and interpolation are visible.
    public static func synthetic(width: Int, height: Int, color: (UInt8, UInt8, UInt8), t: Double) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let bar = max(2, width / 8)
        let x0 = Int((Double(width - bar) * max(0, min(1, t))).rounded())
        for y in 0..<height {
            let shade = 0.6 + 0.4 * Double(y) / Double(max(1, height - 1))
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x >= x0 && x < x0 + bar {
                    out[i] = 235; out[i + 1] = 235; out[i + 2] = 235
                } else {
                    out[i] = UInt8(Double(color.2) * shade); out[i + 1] = UInt8(Double(color.1) * shade); out[i + 2] = UInt8(Double(color.0) * shade)
                }
            }
        }
        return out
    }
}
