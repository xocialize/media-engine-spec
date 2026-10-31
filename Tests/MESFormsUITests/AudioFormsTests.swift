import AppKit
import AVFoundation
import Foundation
import MESClientKit
import MESCore
import MESEngineCore
@testable import MESFormsUI
import MESInProcess
@testable import MockEngineCore
import SwiftUI
import Testing

// MESFormsUI for Audio 0.1: the `voice` widget filled from the chosen model's list (Base §6.5), streaming in the
// request (§7.1), the PCM stream player's conversion, and the audio views rendered offscreen.

func audioDescriptor(_ op: String) async -> Descriptor { await MockAudioEngine().descriptors().first { $0.operation == op }! }

/// Renders a view offscreen and returns its size (AB-L-0215: agent sessions can't screenshot the Mac).
@MainActor func render<V: View>(_ view: V, width: CGFloat = 360) -> CGSize {
    let host = NSHostingView(rootView: view.frame(width: width))
    host.frame.size = host.fittingSize
    host.layoutSubtreeIfNeeded()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
    return host.bounds.size
}

@Suite("MESFormsUI: audio", .serialized)
@MainActor
struct AudioFormsTests {
    @Test("The voice hint (and a parameter named voice) gets the voice widget")
    func voiceWidget() async {
        let speak = OperationFormModel(descriptor: await audioDescriptor("audio.speak"))
        #expect(field(speak.fields, "voice").widget == .voice)
        #expect(FormSchema.widget(name: "voice", schema: ["type": "string"], hint: nil) == .voice)
        #expect(FormSchema.widget(name: "narrator", schema: ["type": "string"], hint: "voice") == .voice)
        #expect(speak.mediaInputs.map(\.name) == ["voice_ref"])
    }

    @Test("Voices follow the effective model; a voice it doesn't list is an issue; the chosen voice speaks")
    func voices() async throws {
        let engine = try await InProcessEngine.start(engine: MockMediaEngine(), configuration: engineConfig())
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.speak"))
        await form.loadVoices()
        #expect(form.voices.isEmpty && form.voicesError == nil, "no source: the widget takes an id as text")

        form.voiceSource = VoiceSource(engine: engine)
        await form.loadVoices()
        #expect(form.voicesModel == "mock-presets" && form.voices.map(\.id) == ["mock-alto", "mock-tenor", "mock-bass"])
        #expect(form.voiceChoices.voices.count == 3 && form.voiceChoices.model?.id == "mock-presets")

        form.setValue("mock-nobody", at: ["voice"])
        #expect(form.issues["voice"]?.contains("mock-nobody") == true)
        form.setValue("mock-bass", at: ["voice"])
        #expect(form.issues["voice"] == nil)

        form.text["text"] = "Hello from the form."
        let job = try await engine.run(form.request())
        #expect(job.outcome == .succeeded && job.result?.provenance.voice?.id == "mock-bass")

        form.model = "mock-clone"
        #expect(form.voiceChoices.voices.isEmpty, "the list belongs to the model it was loaded for")
        await form.loadVoices()
        #expect(form.voicesModel == "mock-clone" && form.voices.isEmpty)
        await engine.stop()
    }

    @Test("Streaming: offered when some offer streams, refused for a model that doesn't, and its chunks arrive")
    func streaming() async throws {
        let engine = try await InProcessEngine.start(engine: MockMediaEngine(), configuration: engineConfig())
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.speak"))
        #expect(form.streamableOutputs.map(\.name) == ["audio"] && form.canStream)
        form.stream = true
        form.model = "mock-presets"
        #expect(!form.canStream && form.request().stream == nil, "mock-presets doesn't stream")
        form.model = nil
        #expect(form.request().stream == [StreamRequest(output: "audio")])
        form.reset()
        #expect(!form.stream)

        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        _ = try Tones.writeWAV(Tones.tone(180, seconds: 3, rate: 24_000), rate: 24_000, channels: 1, to: clip)
        let asset = try await engine.createAsset(contentsOf: clip, ttl: .seconds(600))
        form.stream = true
        form.text["text"] = "Streamed from a form."
        let count = Locked(0)
        let job = try await engine.runStreaming(form.request(media: ["voice_ref": .one(.asset(asset.assetID))])) { _ in count.add() }
        #expect(job.outcome == .succeeded && job.plan?.model.id == "mock-clone" && count.value > 1)
        let generate = OperationFormModel(descriptor: await audioDescriptor("audio.generate"))
        generate.stream = true
        #expect(!generate.canStream && generate.request().stream == nil, "generate's output doesn't stream")
        await engine.stop()
    }

    @Test("PCMStreamPlayer turns interleaved s16 and f32 chunks into deinterleaved float buffers")
    func pcmBuffers() throws {
        let stereo = StreamPlan(output: "audio", encoding: .pcmS16LE, sampleRate: 24_000, channels: 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        var s16 = Data()
        for v: Int16 in [16384, -16384, 32767, 0] { withUnsafeBytes(of: v.littleEndian) { s16.append(contentsOf: $0) } }
        let a = try #require(PCMStreamPlayer.buffer(s16, format: stereo, as: format))
        #expect(a.frameLength == 2)
        #expect(a.floatChannelData![0][0] == 0.5 && a.floatChannelData![1][0] == -0.5 && a.floatChannelData![1][1] == 0)

        let mono = StreamPlan(output: "audio", encoding: .pcmF32LE, sampleRate: 22_050, channels: 1)
        let monoFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        var f32 = Data()
        for v: Float in [0.25, -1, 0.75] { withUnsafeBytes(of: v.bitPattern.littleEndian) { f32.append(contentsOf: $0) } }
        let b = try #require(PCMStreamPlayer.buffer(f32, format: mono, as: monoFormat))
        #expect(b.frameLength == 3 && b.floatChannelData![0][2] == 0.75)
        #expect(PCMStreamPlayer.buffer(Data(), format: mono, as: monoFormat) == nil)
        #expect(AudioPlayback.time(75.9) == "1:15")
    }

    @Test("The audio views render: the voice widget with its list, the input well, the player, the speak form")
    func views() async throws {
        let voices = MockAudioEngine.voices
        let picker = FieldRow(field: FormField(name: "voice", label: "Voice", help: nil, group: nil, order: 0, advanced: false,
                                               required: false, schema: ["type": "string"], widget: .voice, defaultValue: nil),
                              value: .constant("mock-bass"))
            .environment(\.voiceChoices, VoiceChoices(voices: voices))
        #expect(render(picker).height > 40, "the picker and the voice's licence line")
        #expect(render(VoiceEditor(field: field(OperationFormModel(descriptor: await audioDescriptor("audio.speak")).fields, "voice"),
                                   value: .constant(nil))).height > 10, "no list: an id field")

        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        _ = try Tones.writeWAV(Tones.tone(220, seconds: 1.5, rate: 24_000), rate: 24_000, channels: 1, to: clip)
        #expect(AudioPlayerView.facts(clip) == "24 kHz · mono · 16-bit")
        let playback = AudioPlayback()
        try playback.load(clip)
        #expect(abs(playback.duration - 1.5) < 0.01 && !playback.isPlaying)
        #expect(render(AudioPlayerView(file: clip, title: "Output 0")).height > 20)
        let spec = InputSpec(name: "voice_ref", kind: .audio, required: false, mediaTypes: ["audio/wav", "audio/mp4"])
        #expect(render(AudioInputWell(spec: spec, file: .constant(clip))).height > render(AudioInputWell(spec: spec, file: .constant(nil))).height)
        #expect(AudioInputWell(spec: spec, file: .constant(nil)).accepts(clip))
        #expect(!AudioInputWell(spec: spec, file: .constant(nil)).accepts(URL(fileURLWithPath: "/tmp/x.png")))

        let form = OperationFormModel(descriptor: await audioDescriptor("audio.speak"))
        #expect(render(OperationFormContent(form: form) { AudioInputWell(spec: $0, file: .constant(nil)) }).height > 600)
    }
}

/// A counter the streaming callback can bump.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

extension Locked where Value == Int {
    func add() { mutate { $0 += 1 } }
}
