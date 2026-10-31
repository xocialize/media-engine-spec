import AppKit
import AVFoundation
import AVKit
import DesignScaffold
import MESClientKit
import MESCore
import SwiftUI
import UniformTypeIdentifiers

// Video in forms (Video 0.1): a well for video inputs that picks a file and plays it, a player for video outputs with
// their facts, frame previews (thumbnails of a file, or the stills a running job sends, Base §11), and the acceptance a
// licence asks of each user (Base §10.2 rule 4).

// MARK: - Facts

/// What a clip is, in one line: "1280×704 · 24 fps · 121 frames · 5.04 s · sound 48 kHz stereo".
public struct VideoFacts: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var frames: Int?
    public var durationSeconds: Double
    /// The audio track's rate and channels; nil for a silent clip.
    public var sampleRate: Int?
    public var channels: Int?

    public init(width: Int, height: Int, fps: Double, frames: Int? = nil, durationSeconds: Double, sampleRate: Int? = nil,
                channels: Int? = nil) {
        self.width = width; self.height = height; self.fps = fps; self.frames = frames; self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate; self.channels = channels
    }

    /// An output's facts as the engine reported them (Base §10.1); nil when it reports no size and rate.
    public init?(output: Output) {
        guard let w = output.width, let h = output.height, let fps = output.fps else { return nil }
        self.init(width: w, height: h, fps: fps, frames: output.frames,
                  durationSeconds: output.durationSeconds ?? output.frames.map { Double($0) / fps } ?? 0,
                  sampleRate: output.sampleRate, channels: output.channels)
    }

    /// A file's facts, read with AVFoundation (the frame count is the duration × the rate, rounded).
    public static func read(_ file: URL) async throws -> VideoFacts {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        var facts = VideoFacts(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
                               fps: (Double(rate) * 1000).rounded() / 1000, frames: Int((duration * Double(rate)).rounded()),
                               durationSeconds: duration)
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await audio.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            facts.sampleRate = Int(asbd.mSampleRate)
            facts.channels = Int(asbd.mChannelsPerFrame)
        }
        return facts
    }

    public var line: String {
        let fpsText = fps == fps.rounded() ? "\(Int(fps)) fps" : String(format: "%.3g fps", fps)
        var parts = ["\(width)×\(height)", fpsText]
        if let frames { parts.append("\(frames) frames") }
        parts.append(String(format: "%.2f s", durationSeconds))
        if let rate = sampleRate {
            let khz = rate % 1000 == 0 ? "\(rate / 1000) kHz" : String(format: "%.1f kHz", Double(rate) / 1000)
            let ch = channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(channels ?? 0) channels"
            parts.append("sound \(khz) \(ch)")
        } else {
            parts.append("silent")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Player

/// A player for a video output (or any clip): the picture with its controls, and a line of facts. Pass the output's
/// reported facts when you have them; otherwise the file's are read.
public struct VideoPlayerView: View {
    let file: URL
    let title: String?
    let reported: VideoFacts?
    @State private var player: AVPlayer?
    @State private var facts: VideoFacts?
    @State private var failure: String?

    public init(file: URL, title: String? = nil, facts: VideoFacts? = nil) {
        self.file = file
        self.title = title
        reported = facts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let title { Text(title).lineLimit(1) }
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(Color.black)
                if let player { PlayerSurface(player: player) }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .accessibilityLabel("Video \(file.lastPathComponent)")
            if let line = failure ?? (reported ?? facts)?.line {
                Text(line).font(Tokens.Font.caption).foregroundStyle(failure == nil ? Tokens.Color.secondaryLabel : Tokens.Color.failure)
            }
        }
        .task(id: file) {
            player = AVPlayer(url: file)
            do {
                facts = try await VideoFacts.read(file)
                failure = nil
            } catch {
                failure = "Can't read \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        .onDisappear { player?.pause() }
    }

    var aspect: CGFloat {
        guard let f = reported ?? facts, f.height > 0 else { return 16 / 9 }
        return CGFloat(f.width) / CGFloat(f.height)
    }
}

/// AVKit's player view with its inline controls. (AppKit's `AVPlayerView` rather than SwiftUI's `VideoPlayer`, whose
/// overlay can't load in a process without an app, such as a test run.)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Inputs

/// A media slot for a video input: choose a file (or drop one), see it play with its facts, clear it.
///
///     OperationForm(form: form) { spec in
///         if spec.kind == .video { VideoInputWell(spec: spec, file: $files[spec.name]) } else { … }
///     }
public struct VideoInputWell: View {
    let spec: InputSpec
    @Binding var file: URL?
    @State private var dropping = false

    public init(spec: InputSpec, file: Binding<URL?>) {
        self.spec = spec
        _file = file
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "film").foregroundStyle(Tokens.Color.secondaryLabel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"))
                    Text(file?.lastPathComponent ?? spec.notes ?? "A video file")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
                }
                Spacer()
                Button(file == nil ? "Choose…" : "Replace…", action: choose)
                if file != nil {
                    Button { file = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear \(FormSchema.label(spec.name))")
                }
            }
            if let file {
                VideoPlayerView(file: file)
                FramePreviewStrip(file: file, count: 6)
            }
        }
        .padding(Tokens.Space.s)
        .background(dropping ? Tokens.Color.selectionWash : Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .strokeBorder(Tokens.Color.separator, style: StrokeStyle(lineWidth: Tokens.Layout.hairline, dash: file == nil ? [4, 3] : [])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: accepts) else { return false }
            file = first
            return true
        } isTargeted: { dropping = $0 }
    }

    /// The content types the input takes: its `media_types`, else any movie.
    var contentTypes: [UTType] {
        let listed = (spec.mediaTypes ?? []).compactMap { UTType(mimeType: $0) }
        return listed.isEmpty ? [.movie] : listed
    }

    func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose \(FormSchema.label(spec.name).lowercased())"
        if panel.runModal() == .OK, let url = panel.url { file = url }
    }
}

// MARK: - Frame previews

/// One still of a clip: the moment it shows, its frame index when known, and the image.
public struct FramePreview: Identifiable, Sendable, Equatable {
    public var atSeconds: Double
    public var frame: Int?
    public var image: Data
    public var mediaType: String
    public var id: Double { atSeconds }

    public init(atSeconds: Double, frame: Int? = nil, image: Data, mediaType: String = "image/jpeg") {
        self.atSeconds = atSeconds; self.frame = frame; self.image = image; self.mediaType = mediaType
    }
}

/// The stills a running job sends (`job.preview` with `at_s`, Base §11, Video §1.14), in time order: feed it the job's
/// events. A preview without inline data or a time is skipped (an `href` one is the host's to fetch).
@MainActor @Observable
public final class FramePreviews {
    public private(set) var frames: [FramePreview] = []
    /// Only previews of this output, when set.
    public var output: String?

    public init(output: String? = nil) { self.output = output }

    /// Takes one event; returns whether it added a still.
    @discardableResult
    public func ingest(_ event: Event) -> Bool {
        guard event.type == .preview, let data = event.data.objectValue,
              let at = data["at_s"]?.numberValue, let encoded = data["data"]?.stringValue, let image = Data(base64Encoded: encoded) else {
            return false
        }
        if let output, let named = data["output"]?.stringValue, named != output { return false }
        let preview = FramePreview(atSeconds: at, frame: data["frame"]?.intValue, image: image,
                                   mediaType: data["media_type"]?.stringValue ?? "image/jpeg")
        frames.removeAll { $0.atSeconds == at }
        frames.append(preview)
        frames.sort { $0.atSeconds < $1.atSeconds }
        return true
    }

    public func reset() { frames = [] }
}

/// Thumbnails of a clip's frames, evenly spaced (AVAssetImageGenerator).
public enum FrameThumbnails {
    public static func make(_ file: URL, count: Int, maxSide: CGFloat = 160) async throws -> [FramePreview] {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        var out: [FramePreview] = []
        for i in 0..<count {
            let t = count == 1 ? 0 : duration * Double(i) / Double(count)
            let (image, actual) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: image)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            out.append(FramePreview(atSeconds: actual.seconds, image: png, mediaType: "image/png"))
        }
        return out
    }
}

/// A row of stills with their times: a clip's thumbnails (from a file) or a running job's previews.
public struct FramePreviewStrip: View {
    let file: URL?
    let count: Int
    let given: [FramePreview]?
    @State private var thumbnails: [FramePreview] = []

    /// Thumbnails of a file.
    public init(file: URL, count: Int = 8) { self.file = file; self.count = count; given = nil }
    /// Stills you have, such as `FramePreviews.frames`.
    public init(frames: [FramePreview]) { file = nil; count = frames.count; given = frames }

    public var body: some View {
        let frames = given ?? thumbnails
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(frames) { frame in
                    VStack(spacing: 2) {
                        if let image = NSImage(data: frame.image) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text(String(format: "%.2f s", frame.atSeconds)).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Frame at \(String(format: "%.2f", frame.atSeconds)) seconds")
                }
            }
        }
        .task(id: file) {
            guard given == nil, let file else { return }
            thumbnails = (try? await FrameThumbnails.make(file, count: count)) ?? []
        }
    }
}

// MARK: - Licence acceptance (Base §10.2 rule 4)

/// The licences this client's user has accepted, by `spdx`, kept in `UserDefaults` (or only in memory). A form sends
/// them in `policy.accepted` for the offers whose licences need them.
///
///     form.acceptances = .shared
@MainActor @Observable
public final class LicenseAcceptances {
    public private(set) var accepted: Set<String>
    @ObservationIgnored let defaults: UserDefaults?
    @ObservationIgnored let key: String

    /// - Parameter defaults: where acceptances persist; nil keeps them in memory only.
    public init(defaults: UserDefaults? = nil, key: String = "MESFormsUI.acceptedLicenses") {
        self.defaults = defaults
        self.key = key
        accepted = Set(defaults?.stringArray(forKey: key) ?? [])
    }

    /// This user's acceptances, kept in the standard defaults.
    public static let shared = LicenseAcceptances(defaults: .standard)

    public func isAccepted(_ license: License) -> Bool { !license.needsUserAcceptance || accepted.contains(license.spdx) }

    public func accept(_ license: License) { update { $0.insert(license.spdx) } }
    public func revoke(_ license: License) { update { $0.remove(license.spdx) } }

    func update(_ change: (inout Set<String>) -> Void) {
        change(&accepted)
        defaults?.set(accepted.sorted(), forKey: key)
    }
}

/// A licence whose users must accept it: its notice, a link to the terms, and Accept (Base §10.2 rule 4).
public struct LicenseAcceptanceView: View {
    let license: License
    let title: String
    let acceptances: LicenseAcceptances

    public init(license: License, title: String, acceptances: LicenseAcceptances) {
        self.license = license; self.title = title; self.acceptances = acceptances
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text("\(title) is under \(license.spdx), whose terms bind each person who uses it.").font(Tokens.Font.caption)
            if let notice = license.notice { Text(notice).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel) }
            HStack(spacing: Tokens.Space.s) {
                if let url = license.termsURL.flatMap(URL.init(string:)) { Link("Read the terms", destination: url).font(Tokens.Font.caption) }
                Spacer()
                if acceptances.isAccepted(license) {
                    Label("Accepted", systemImage: "checkmark.seal").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.ready)
                } else {
                    Button("Accept the terms") { acceptances.accept(license) }.controlSize(.small)
                }
            }
        }
        .padding(Tokens.Space.s)
        .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .accessibilityElement(children: .contain)
    }
}
