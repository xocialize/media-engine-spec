import CoreGraphics
import Foundation
import ImageIO
import MESCore
import UniformTypeIdentifiers

/// An sRGB RGBA8 raster (premultiplied, as CoreGraphics draws it). The mock engine works on these: decode with
/// orientation applied (Image §1.4), convert to sRGB (§1.3), operate, encode PNG.
struct Raster: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = fill.0; pixels[i + 1] = fill.1; pixels[i + 2] = fill.2; pixels[i + 3] = fill.3
        }
    }

    init(width: Int, height: Int, pixels: [UInt8]) { self.width = width; self.height = height; self.pixels = pixels }

    subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        get {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
        set {
            let i = (y * width + x) * 4
            pixels[i] = newValue.0; pixels[i + 1] = newValue.1; pixels[i + 2] = newValue.2; pixels[i + 3] = newValue.3
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Decodes a file with EXIF orientation applied; reports whether a colour conversion to sRGB happened.
    static func load(_ url: URL) throws -> (Raster, colorConverted: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw MESError(.inputInvalid, "The input isn't a decodable image.")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MESError(.inputInvalid, "The input couldn't be decoded.")
        }
        let converted = image.colorSpace.map { $0.name != CGColorSpace.sRGB && $0.model == .rgb } ?? false
        return (try draw(image), converted)
    }

    static func draw(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> Raster {
        let w = width ?? image.width, h = height ?? image.height
        var raster = Raster(width: w, height: h, fill: (0, 0, 0, 0))
        try raster.pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw MESError(.engineError, "Couldn't create a drawing context.")
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return raster
    }

    /// A greyscale mask resampled to (width, height) if needed; returns whether it was resampled.
    static func loadMask(_ url: URL, width: Int, height: Int) throws -> ([UInt8], resampled: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MESError(.inputInvalid, "The mask isn't a decodable image.")
        }
        var grey = [UInt8](repeating: 0, count: width * height)
        try grey.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw MESError(.engineError, "Couldn't create a mask context.")
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (grey, image.width != width || image.height != height)
    }

    func cgImage() -> CGImage {
        let data = CFDataCreate(nil, pixels, pixels.count)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Raster.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    func writePNG(to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MESError(.engineError, "Couldn't create a PNG.")
        }
        CGImageDestinationAddImage(dest, cgImage(), nil)
        guard CGImageDestinationFinalize(dest) else { throw MESError(.engineError, "Couldn't write a PNG.") }
    }

    static func writeGreyPNG(_ grey: [UInt8], width: Int, height: Int, to url: URL) throws {
        let data = CFDataCreate(nil, grey, grey.count)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MESError(.engineError, "Couldn't create a PNG.")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MESError(.engineError, "Couldn't write a PNG.") }
    }

    func luminance(_ x: Int, _ y: Int) -> Int {
        let p = self[x, y]
        return (Int(p.0) * 299 + Int(p.1) * 587 + Int(p.2) * 114) / 1000
    }

    var meanColor: (UInt8, UInt8, UInt8) {
        var r = 0, g = 0, b = 0
        for i in stride(from: 0, to: pixels.count, by: 4) { r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2]) }
        let n = max(1, width * height)
        return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
    }
}

/// Deterministic colours from text and a seed, so the same request gives the same mock result.
enum Palette {
    static func color(_ text: String, seed: Int) -> (UInt8, UInt8, UInt8) {
        var h: UInt64 = 1469598103934665603
        for byte in "\(seed):\(text)".utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return (UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h >> 16))
    }

    static func blend(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        UInt8(max(0, min(255, (Double(a) * (1 - t) + Double(b) * t).rounded())))
    }
}
