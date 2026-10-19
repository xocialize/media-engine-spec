import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Mac's own artwork for the Overview page, from CoreTypes and the device's UTType. Ported from Nativ (MIT, see
// THIRD-PARTY-NOTICES.md).

struct SystemDeviceArtwork: View {
    let identity: SystemMonitorIdentity

    var body: some View {
        Group {
            if let image = SystemDeviceArtworkProvider.image(for: identity) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityLabel("\(identity.computerName) device image")
            } else {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 50, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("\(identity.computerName) device")
            }
        }
        .frame(width: 220, height: 126)
    }
}

@MainActor
private enum SystemDeviceArtworkProvider {
    private static let coreTypesResourcesURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle"
    )
    .appendingPathComponent("Contents/Resources", isDirectory: true)

    private static let imageCache = NSCache<NSString, NSImage>()
    private static let deviceModelCodeTagClass = UTTagClass(
        rawValue: "com.apple.device-model-code"
    )
    private static let motionPurpleWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Motion Purple Dark.heic"
    )
    private static let radialSkyBlueWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Radial Sky Blue.heic"
    )
    private static let radialYellowWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Radial Yellow.heic"
    )
    private static let proBlackWallpaper = NSImage(
        contentsOfFile: "/System/Library/Desktop Pictures/.thumbnails/Pro Black.heic"
    )
    private static let notchedMacBookAir13Models: Set<String> = [
        "Mac14,2", "Mac15,12", "Mac16,12", "Mac17,3",
    ]
    private static let notchedMacBookAir15Models: Set<String> = [
        "Mac14,15", "Mac15,13", "Mac16,13", "Mac17,4",
    ]

    static func image(for identity: SystemMonitorIdentity) -> NSImage? {
        if let contentType = contentType(for: identity) {
            let cacheKey = "content-type:\(contentType.identifier)" as NSString
            if let cachedImage = imageCache.object(forKey: cacheKey) {
                return cachedImage
            }

            let sourceImage = NSWorkspace.shared.icon(for: contentType)
            let image = identity.computerName
                .localizedCaseInsensitiveContains("macbook")
                ? croppedLaptopImage(
                    sourceImage,
                    wallpaper: wallpaper(for: identity),
                    layout: laptopArtworkLayout(
                        for: contentType.identifier
                    )
                )
                : sourceImage
            imageCache.setObject(image, forKey: cacheKey)
            return image
        }

        guard let resourceName = resourceName(for: identity) else {
            return NSImage(named: NSImage.computerName)
        }
        if let cachedImage = imageCache.object(forKey: resourceName as NSString) {
            return cachedImage
        }

        let imageURL = coreTypesResourcesURL
            .appendingPathComponent(resourceName)
            .appendingPathExtension("icns")
        guard let sourceImage = NSImage(contentsOf: imageURL) else {
            return NSImage(named: NSImage.computerName)
        }

        let image: NSImage
        if resourceName.contains("macbook") {
            image = croppedLaptopImage(
                sourceImage,
                wallpaper: wallpaper(for: identity),
                layout: laptopArtworkLayout(for: resourceName)
            )
        } else {
            image = sourceImage
        }
        imageCache.setObject(image, forKey: resourceName as NSString)
        return image
    }

    private static func contentType(
        for identity: SystemMonitorIdentity
    ) -> UTType? {
        for deviceModelCode in artworkModelCodeCandidates(for: identity) {
            if let contentType = UTType(
                tag: deviceModelCode,
                tagClass: deviceModelCodeTagClass,
                conformingTo: nil
            ), contentType.isDeclared {
                return contentType
            }
        }
        return nil
    }

    private static func artworkModelCodeCandidates(
        for identity: SystemMonitorIdentity
    ) -> [String] {
        let currentModelIdentifier: String
        if notchedMacBookAir13Models.contains(identity.modelIdentifier) {
            currentModelIdentifier = "Mac17,3"
        } else if notchedMacBookAir15Models.contains(identity.modelIdentifier) {
            currentModelIdentifier = "Mac17,4"
        } else {
            return identity.deviceModelCodeCandidates
        }

        var candidates: [String] = []
        if let enclosureColorCode = identity.enclosureColorCode,
           !enclosureColorCode.isEmpty {
            candidates.append(
                "\(currentModelIdentifier)@ECOLOR=\(enclosureColorCode)"
            )
        } else {
            candidates.append(currentModelIdentifier)
        }
        for candidate in identity.deviceModelCodeCandidates
            where !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        return candidates
    }

    private static func wallpaper(
        for identity: SystemMonitorIdentity
    ) -> NSImage? {
        if identity.computerName
            .localizedCaseInsensitiveContains("MacBook Pro") {
            return proBlackWallpaper ?? motionPurpleWallpaper
        }
        if notchedMacBookAir15Models.contains(identity.modelIdentifier) {
            return radialYellowWallpaper ?? motionPurpleWallpaper
        }
        if notchedMacBookAir13Models.contains(identity.modelIdentifier) {
            return radialSkyBlueWallpaper ?? motionPurpleWallpaper
        }
        return motionPurpleWallpaper
    }

    private static func resourceName(
        for identity: SystemMonitorIdentity
    ) -> String? {
        let machineName = identity.computerName.lowercased()

        if machineName.contains("macbook pro") {
            let sixteenInchModels: Set<String> = [
                "MacBookPro16,1", "MacBookPro16,4",
                "MacBookPro18,1", "MacBookPro18,2",
                "Mac14,6", "Mac14,10",
                "Mac15,7", "Mac15,9", "Mac15,11",
            ]
            let size = sixteenInchModels.contains(identity.modelIdentifier)
                ? "16"
                : "14"
            return "com.apple.macbookpro-\(size)-2021-space-gray"
        }
        if machineName.contains("macbook air") {
            return "com.apple.macbookair-13-2022-midnight"
        }
        if machineName.contains("mac studio") {
            return "com.apple.macstudio"
        }
        if machineName.contains("mac mini") {
            return "com.apple.macmini-2020"
        }
        if machineName.contains("imac") {
            return "com.apple.imac-2021-silver"
        }
        if machineName.contains("mac pro") {
            return "com.apple.macpro-2019"
        }
        return nil
    }

    private static func croppedLaptopImage(
        _ sourceImage: NSImage,
        wallpaper: NSImage?,
        layout: LaptopArtworkLayout
    ) -> NSImage {
        let sourceSize = sourceImage.size
        let sourceRect = NSRect(
            x: sourceSize.width * 0.065,
            y: sourceSize.height * 0.18,
            width: sourceSize.width * 0.87,
            height: sourceSize.height * 0.56
        )
        let outputSize = NSSize(width: 220, height: 140)
        return NSImage(size: outputSize, flipped: false) { outputRect in
            sourceImage.draw(
                in: outputRect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: 1
            )
            drawLaptopWallpaper(
                wallpaper,
                in: outputRect,
                layout: layout
            )
            return true
        }
    }

    private struct LaptopArtworkLayout {
        let screenRect: NSRect
        let hasNotch: Bool

        static let notchless13 = LaptopArtworkLayout(
            screenRect: NSRect(x: 0.17, y: 0.18, width: 0.66, height: 0.66),
            hasNotch: false
        )
        static let air13 = LaptopArtworkLayout(
            screenRect: NSRect(x: 0.17, y: 0.16, width: 0.66, height: 0.68),
            hasNotch: true
        )
        static let air15 = LaptopArtworkLayout(
            screenRect: NSRect(x: 0.12, y: 0.16, width: 0.76, height: 0.77),
            hasNotch: true
        )
        static let pro14 = LaptopArtworkLayout(
            screenRect: NSRect(x: 0.157, y: 0.18, width: 0.686, height: 0.69),
            hasNotch: true
        )
        static let pro16 = LaptopArtworkLayout(
            screenRect: NSRect(x: 0.102, y: 0.178, width: 0.796, height: 0.804),
            hasNotch: true
        )
    }

    private static func laptopArtworkLayout(
        for artworkIdentifier: String
    ) -> LaptopArtworkLayout {
        let identifier = artworkIdentifier.lowercased()

        if identifier.contains("macbookair-late-2020")
            || identifier.contains("macbookpro-13") {
            return .notchless13
        }
        if identifier.contains("macbookair-15") {
            return .air15
        }
        if identifier.contains("macbookair-13") {
            return .air13
        }
        if identifier.contains("macbookpro-14") {
            return .pro14
        }
        if identifier.contains("macbookpro-16") {
            return .pro16
        }
        return .pro16
    }

    private static func drawLaptopWallpaper(
        _ wallpaper: NSImage?,
        in rect: NSRect,
        layout: LaptopArtworkLayout
    ) {
        guard let wallpaper else { return }

        let screenRect = NSRect(
            x: rect.minX + (rect.width * layout.screenRect.minX),
            y: rect.minY + (rect.height * layout.screenRect.minY),
            width: rect.width * layout.screenRect.width,
            height: rect.height * layout.screenRect.height
        )
        let wallpaperSize = wallpaper.size
        let targetAspectRatio = screenRect.width / screenRect.height
        let sourceAspectRatio = wallpaperSize.width / wallpaperSize.height
        let wallpaperSourceRect: NSRect

        if sourceAspectRatio > targetAspectRatio {
            let width = wallpaperSize.height * targetAspectRatio
            wallpaperSourceRect = NSRect(
                x: (wallpaperSize.width - width) / 2,
                y: 0,
                width: width,
                height: wallpaperSize.height
            )
        } else {
            let height = wallpaperSize.width / targetAspectRatio
            wallpaperSourceRect = NSRect(
                x: 0,
                y: (wallpaperSize.height - height) / 2,
                width: wallpaperSize.width,
                height: height
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: screenRect,
            xRadius: 0.8,
            yRadius: 0.8
        ).addClip()
        wallpaper.draw(
            in: screenRect,
            from: wallpaperSourceRect,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard layout.hasNotch else { return }

        let notchRect = NSRect(
            x: rect.midX - (rect.width * 0.041),
            y: screenRect.maxY - (rect.height * 0.027),
            width: rect.width * 0.082,
            height: rect.height * 0.027
        )
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: notchRect,
            xRadius: 1.8,
            yRadius: 1.8
        ).fill()
    }
}
