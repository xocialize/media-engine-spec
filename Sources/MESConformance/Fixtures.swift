import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MESCore
import UniformTypeIdentifiers

/// The JSON Schemas of `schemas/v0`, bundled (a test keeps the copy identical to the repo's).
public struct Schemas: Sendable {
    let root: URL
    let loader = SchemaLoader()

    public init() {
        root = Bundle.module.url(forResource: "schemas", withExtension: nil)!.appendingPathComponent("v0")
    }

    /// Issues validating `value` against `target` (`base/job.schema.json`, optionally `#/$defs/…`).
    public func issues(_ value: JSONValue, _ target: String) -> [SchemaValidator.Issue] {
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        let url = root.appendingPathComponent(parts[0])
        guard let document = loader.load(url) else { return [.init(path: "$", message: "no schema \(target)")] }
        var node = document
        if parts.count > 1 { for key in parts[1].split(separator: "/") { node = node[String(key)] ?? .null } }
        return SchemaValidator(loader: loader).validate(value, against: node, in: document, base: url)
    }

    public func require(_ value: JSONValue, _ target: String, _ what: String) throws {
        let found = issues(value, target)
        try check(found.isEmpty, "\(what) doesn't match \(target): \(found.prefix(3).map(\.description).joined(separator: "; "))")
    }

    public func require(_ body: Data, _ target: String, _ what: String) throws {
        guard let value = try? MESJSON.decoder.decode(JSONValue.self, from: body) else {
            throw Failure("\(what) isn't JSON: \(String(decoding: body.prefix(200), as: UTF8.self))")
        }
        try require(value, target, what)
    }
}

/// Test media, made in memory: no files ship with the suite.
public enum Fixtures {
    /// An opaque sRGB gradient, as PNG.
    public static func png(width: Int = 64, height: Int = 48) -> Data {
        draw(width: width, height: height, space: CGColorSpace(name: CGColorSpace.sRGB)!) { x, y in
            (UInt8(x * 255 / max(1, width - 1)), UInt8(y * 255 / max(1, height - 1)), 96, 255)
        }
    }

    /// The same picture in Display P3, with its profile embedded (IMAGE-006).
    public static func displayP3PNG(width: Int = 64, height: Int = 48) -> Data {
        draw(width: width, height: height, space: CGColorSpace(name: CGColorSpace.displayP3)!) { x, y in
            (UInt8(x * 255 / max(1, width - 1)), 40, UInt8(y * 255 / max(1, height - 1)), 255)
        }
    }

    /// An 8-bit grey mask: black (keep) on the left half, white (change) on the right.
    public static func mask(width: Int = 64, height: Int = 48) -> Data {
        let space = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where x >= width / 2 { pixels[y * width + x] = 255 } }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return ctx.makeImage()!
        }
        return encode(image, type: .png)
    }

    /// A JPEG stored `storedWidth × storedHeight` with EXIF orientation 6 (rotate 90° clockwise to view), so it displays
    /// `storedHeight × storedWidth` (IMAGE-005).
    public static func orientedJPEG(storedWidth: Int = 64, storedHeight: Int = 32) -> Data {
        let data = draw(width: storedWidth, height: storedHeight, space: CGColorSpace(name: CGColorSpace.sRGB)!) { x, _ in
            x < storedWidth / 4 ? (255, 0, 0, 255) : (200, 200, 200, 255)
        }
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return encode(image, type: .jpeg, properties: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95])
    }

    static func draw(width: Int, height: Int, space: CGColorSpace,
                     _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
        let image = bytes.withUnsafeMutableBytes { buffer -> CGImage in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        return encode(image, type: .png)
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

extension Fixtures {
    /// Speech-like audio: tone bursts with gaps, as a WAV. `bits` 16, 24 or 32 (32 is IEEE float).
    public static func wav(seconds: Double = 2, rate: Int = 24000, channels: Int = 1, bits: Int = 16) -> Data {
        let mono = speechLike(seconds: seconds, rate: rate)
        var pcm = Data()
        for s in mono {
            for _ in 0..<channels {
                switch bits {
                case 24:
                    let v = Int32(s * 8_388_607)
                    pcm.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff)])
                case 32: withUnsafeBytes(of: s.bitPattern.littleEndian) { pcm.append(contentsOf: $0) }
                default: withUnsafeBytes(of: Int16(s * 32767).littleEndian) { pcm.append(contentsOf: $0) }
                }
            }
        }
        return WAVFile(sampleRate: rate, channels: channels, bitsPerSample: bits, format: bits == 32 ? .float : .int, pcm: pcm).data
    }

    /// The same audio as FLAC, written by AVFoundation (Audio §1.1: engines MUST accept FLAC).
    public static func flac(seconds: Double = 2, rate: Int = 24000) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mes-conformance-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16]
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let mono = speechLike(seconds: seconds, rate: rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mono.count))!
        buffer.frameLength = AVAudioFrameCount(mono.count)
        for (i, s) in mono.enumerated() { buffer.floatChannelData![0][i] = s }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    static func speechLike(seconds: Double, rate: Int) -> [Float] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let word = Int(t / 0.3), inWord = t.truncatingRemainder(dividingBy: 0.3) < 0.22
            let hz = 180 + Double(word % 3) * 20
            return inWord ? Float(0.3 * sin(2 * .pi * hz * t)) : 0
        }
    }
}

/// A decoded output image: its pixels in sRGB RGBA8, and what its file says about itself.
public struct DecodedImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let bitsPerComponent: Int
    public let isGrey: Bool
    public let hasAlpha: Bool
    /// The embedded profile's name, if any.
    public let profile: String?
    /// The EXIF orientation the file carries (1 when none).
    public let orientation: Int

    public init(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure("The output isn't a readable image.") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = orientation >= 5
        width = rotated ? image.height : image.width
        height = rotated ? image.width : image.height
        bitsPerComponent = image.bitsPerComponent
        isGrey = image.colorSpace?.model == .monochrome
        hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        profile = props[kCGImagePropertyProfileName] as? String
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        rgba = pixels
    }

    public func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(rgba[i..<(i + 4)])
    }
}
