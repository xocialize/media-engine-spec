import AppKit
import AVFoundation
import DesignScaffold
import MESClientKit
import MESCore
import SwiftUI
import UniformTypeIdentifiers

// Audio in forms (Audio 0.1): the `voice` widget filled from the chosen model's voice list (Base §6.5), a well for
// audio inputs that picks a file and plays it, a player for audio outputs, and one for streamed PCM (§11).

/// Where a form's voice lists and samples come from: usually an engine connection.
///
///     form.voiceSource = VoiceSource(engine: engine)
public struct VoiceSource: Sendable {
    /// An offer's preset voices: `(operation, model)`.
    public var voices: @Sendable (_ operation: String, _ model: String) async throws -> [Voice]
    /// A voice's `sample` bytes; nil when samples can't be fetched.
    public var sample: (@Sendable (Voice) async throws -> Data)?

    public init(voices: @escaping @Sendable (_ operation: String, _ model: String) async throws -> [Voice],
                sample: (@Sendable (Voice) async throws -> Data)? = nil) {
        self.voices = voices
        self.sample = sample
    }

    /// Voice lists from an engine (revalidated by ETag over HTTP), samples with its authorization.
    public init(engine: any EngineConnection) {
        self.init(voices: { try await engine.voices(operation: $0, model: $1).voices }, sample: { try await engine.sample(of: $0) })
    }
}

/// What the `voice` widget offers: the effective model's voices.
public struct VoiceChoices: Sendable {
    public var voices: [Voice] = []
    public var model: ModelOffer?
    public var loading = false
    public var error: String?
    public var sample: (@Sendable (Voice) async throws -> Data)?
    public init(voices: [Voice] = [], model: ModelOffer? = nil, loading: Bool = false, error: String? = nil,
                sample: (@Sendable (Voice) async throws -> Data)? = nil) {
        self.voices = voices; self.model = model; self.loading = loading; self.error = error; self.sample = sample
    }
}

extension EnvironmentValues {
    /// The voices a form's `voice` fields pick from; `OperationFormContent` sets it from its model.
    @Entry public var voiceChoices = VoiceChoices()
}

// MARK: - The voice widget

/// A preset voice: a picker over the model's list, each voice's languages, tags and own licence, and its sample.
/// With no list (no source, or a model without voices), the id as text.
struct VoiceEditor: View {
    let field: FormField
    @Binding var value: JSONValue?
    @Environment(\.voiceChoices) private var choices
    @State private var playback = AudioPlayback()
    @State private var sampleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            LabeledContent(field.label) {
                if choices.voices.isEmpty {
                    HStack(spacing: Tokens.Space.s) {
                        if choices.loading { ProgressView().controlSize(.mini) }
                        TextField(field.label, text: Binding(get: { value?.stringValue ?? "" }, set: { value = $0.isEmpty ? nil : .string($0) }),
                                  prompt: Text(choices.loading ? "Loading voices…" : "Voice id"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                    }
                } else {
                    HStack(spacing: Tokens.Space.s) {
                        Picker(field.label, selection: Binding(get: { value?.stringValue ?? "" },
                                                               set: { value = $0.isEmpty ? nil : .string($0) })) {
                            Text("Model's default").tag("")
                            ForEach(choices.voices, id: \.id) { voice in Text(voice.title).tag(voice.id) }
                            if let id = value?.stringValue, !choices.voices.contains(where: { $0.id == id }) {
                                Text("\(id) (not offered)").tag(id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let selected, selected.sample != nil, choices.sample != nil {
                            Button { Task { await toggleSample(selected) } } label: {
                                Image(systemName: playback.isPlaying ? "stop.fill" : "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(playback.isPlaying ? "Stop the sample" : "Play a sample of \(selected.title)")
                            .accessibilityLabel(playback.isPlaying ? "Stop sample" : "Play sample")
                        }
                    }
                }
            }
            if let selected {
                VStack(alignment: .leading, spacing: 2) {
                    let facts = (selected.languages ?? []) + (selected.tags ?? [])
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · ")).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                    if let notes = selected.notes {
                        Text(notes).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                    if let license = selected.license { LicenseLine(license: license) }
                }
            }
            if let error = sampleError ?? choices.error {
                Text(error).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure).lineLimit(2)
            }
        }
        .onDisappear { playback.stop() }
    }

    var selected: Voice? { value?.stringValue.flatMap { id in choices.voices.first { $0.id == id } } }

    func toggleSample(_ voice: Voice) async {
        if playback.isPlaying { playback.stop(); return }
        guard let fetch = choices.sample else { return }
        do {
            try playback.load(try await fetch(voice))
            playback.play()
            sampleError = nil
        } catch {
            sampleError = "Couldn't play the sample: \(error)"
        }
    }
}

// MARK: - Playback

/// One sound at a time, for the views here: load a file or bytes, play, pause, seek.
@MainActor @Observable
public final class AudioPlayback {
    public private(set) var isPlaying = false
    public private(set) var duration: TimeInterval = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var finish: Finish?

    public init() {}

    public var currentTime: TimeInterval {
        get { player?.currentTime ?? 0 }
        set { player?.currentTime = max(0, min(newValue, duration)) }
    }

    public func load(_ file: URL) throws { attach(try AVAudioPlayer(contentsOf: file)) }

    public func load(_ data: Data) throws { attach(try AVAudioPlayer(data: data)) }

    public func play() {
        guard let player else { return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        isPlaying = player.play()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
    }

    public func toggle() { isPlaying ? pause() : play() }

    private func attach(_ new: AVAudioPlayer) {
        stop()
        let finish = Finish { [weak self] in self?.isPlaying = false }
        new.delegate = finish
        new.prepareToPlay()
        (player, self.finish, duration) = (new, finish, new.duration)
    }

    /// AVAudioPlayer's delegate, back on the main actor.
    private final class Finish: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let done: @MainActor () -> Void
        init(_ done: @escaping @MainActor () -> Void) { self.done = done }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in done() }
        }
    }

    /// `75` → "1:15".
    public static func time(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A player for an audio output (or any audio file): play and pause, a scrubber, the time, and the file's format.
public struct AudioPlayerView: View {
    let file: URL
    let title: String?
    @State private var playback = AudioPlayback()
    @State private var facts: String?
    @State private var failure: String?

    public init(file: URL, title: String? = nil) {
        self.file = file
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let title { Text(title).lineLimit(1) }
            HStack(spacing: Tokens.Space.s) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 14)
                }
                .buttonStyle(.borderless)
                .disabled(failure != nil)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    HStack(spacing: Tokens.Space.s) {
                        Slider(value: Binding(get: { playback.currentTime }, set: { playback.currentTime = $0 }),
                               in: 0...max(playback.duration, 0.01))
                            .controlSize(.mini)
                            .accessibilityLabel("Position")
                        Text("\(AudioPlayback.time(playback.currentTime)) / \(AudioPlayback.time(playback.duration))")
                            .font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel).fixedSize()
                    }
                }
            }
            if let line = failure ?? facts {
                Text(line).font(Tokens.Font.caption).foregroundStyle(failure == nil ? Tokens.Color.secondaryLabel : Tokens.Color.failure)
            }
        }
        .task(id: file) {
            do {
                try playback.load(file)
                facts = Self.facts(file)
                failure = nil
            } catch {
                failure = "Can't play \(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
        .onDisappear { playback.stop() }
    }

    /// "24 kHz · mono · 16-bit", read from the file.
    static func facts(_ file: URL) -> String? {
        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let format = audio.fileFormat
        let rate = format.sampleRate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(format.sampleRate / 1000)) kHz" : String(format: "%.2f kHz", format.sampleRate / 1000)
        let channels = format.channelCount == 1 ? "mono" : format.channelCount == 2 ? "stereo" : "\(format.channelCount) channels"
        let bits = (format.settings[AVLinearPCMBitDepthKey] as? Int).map { "\($0)-bit" }
        return ([rate, channels] + (bits.map { [$0] } ?? [])).joined(separator: " · ")
    }
}

// MARK: - Audio inputs

/// A media slot for an audio input: choose a file (or drop one), see and play it, clear it.
///
///     OperationForm(form: form) { spec in
///         if spec.kind == .audio { AudioInputWell(spec: spec, file: $files[spec.name]) } else { … }
///     }
public struct AudioInputWell: View {
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
                Image(systemName: "waveform").foregroundStyle(Tokens.Color.secondaryLabel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"))
                    Text(file?.lastPathComponent ?? spec.notes ?? "An audio file")
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
            if let file { AudioPlayerView(file: file) }
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

    /// The content types the input takes: its `media_types`, else any audio.
    var contentTypes: [UTType] {
        let listed = (spec.mediaTypes ?? []).compactMap { UTType(mimeType: $0) }
        return listed.isEmpty ? [.audio] : listed
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

// MARK: - Streamed PCM

/// Plays a streamed output while it arrives (Base §11): each chunk's samples are scheduled as they come, so playback
/// starts with the first chunk rather than the finished file.
///
///     let player = try PCMStreamPlayer(format: plan)
///     _ = try await engine.runStreaming(request) { chunk in try await player.enqueue(chunk) }
///     player.finish()
@MainActor
public final class PCMStreamPlayer {
    public let format: StreamPlan
    public let audioFormat: AVAudioFormat
    /// Frames scheduled so far.
    public private(set) var scheduledFrames = 0
    /// Whether the last chunk has been scheduled.
    public private(set) var finished = false
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var started = false

    public enum Failure: Error { case format(StreamPlan) }

    public init(format: StreamPlan) throws {
        guard let audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(format.sampleRate),
                                              channels: AVAudioChannelCount(format.channels)) else { throw Failure.format(format) }
        self.format = format
        self.audioFormat = audioFormat
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: audioFormat)
    }

    /// Schedules a chunk's samples; the first starts playback. A chunk replayed without samples is skipped.
    public func enqueue(_ chunk: OutputChunk) throws {
        if let samples = chunk.samples { try enqueue(samples) }
        if chunk.final { finish() }
    }

    public func enqueue(_ samples: Data) throws {
        guard !samples.isEmpty, let buffer = Self.buffer(samples, format: format, as: audioFormat) else { return }
        if !started {
            try engine.start()
            node.play()
            started = true
        }
        node.scheduleBuffer(buffer)
        scheduledFrames += Int(buffer.frameLength)
    }

    /// No more chunks: what's scheduled plays out.
    public func finish() { finished = true }

    /// Seconds played so far.
    public var playedSeconds: Double {
        guard started, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    /// Whether everything scheduled has played, after `finish()`.
    public var isDone: Bool { finished && playedSeconds * Double(format.sampleRate) >= Double(scheduledFrames) }

    public func stop() {
        node.stop()
        engine.stop()
        started = false
    }

    /// Interleaved little-endian PCM (`pcm_s16le` or `pcm_f32le`) as a deinterleaved float buffer.
    public nonisolated static func buffer(_ samples: Data, format: StreamPlan, as audioFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channels = format.channels
        let frames = format.frameBytes > 0 ? samples.count / format.frameBytes : 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBytes { raw in
            for f in 0..<frames {
                for c in 0..<channels {
                    let at = (f * channels + c) * format.encoding.sampleBytes
                    switch format.encoding {
                    case .pcmS16LE:
                        out[c][f] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self))) / 32768
                    case .pcmF32LE:
                        out[c][f] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    }
                }
            }
        }
        return buffer
    }
}
