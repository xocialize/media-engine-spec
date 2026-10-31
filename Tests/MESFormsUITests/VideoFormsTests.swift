import AppKit
import Foundation
import MESClientKit
import MESCore
import MESEngineCore
@testable import MESFormsUI
import MESInProcess
@testable import MockEngineCore
import SwiftUI
import Testing

// MESFormsUI for Video 0.1: every video form's widgets, forms that run (with the users' acceptance a licence asks for,
// Base §10.2 rule 4), frame previews from a running job's events, a clip's facts and thumbnails, and the video views
// rendered offscreen.

func videoDescriptor(_ op: String) async -> Descriptor { await MockVideoEngine().descriptors().first { $0.operation == op }! }

func clipFile(frames: Int = 17, audio: Bool = true) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("forms-\(UUID().uuidString).mp4")
    let w = 128, h = 96
    let pictures = (0..<frames).map { Clips.synthetic(width: w, height: h, color: (200, 80, 40), t: Double($0) / Double(frames - 1)) }
    let samples: [Float]? = audio ? [Float](repeating: 0.1, count: 48_000 * frames / 24 * 2) : nil
    try await Clips.write(Clip(width: w, height: h, fps: 24, frames: pictures, audio: samples), to: url)
    return url
}

@Suite("MESFormsUI: video", .serialized)
@MainActor
struct VideoFormsTests {
    @Test("Every field of every video form gets a real widget; keyframe_times is a number list")
    func widgets() async {
        for d in await MockVideoEngine().descriptors() {
            for f in allFields(OperationFormModel(descriptor: d).fields) {
                #expect(f.widget != .json, "\(d.operation).\(f.name) fell back to JSON")
            }
        }
        let generate = OperationFormModel(descriptor: await videoDescriptor("video.generate"))
        #expect(field(generate.fields, "keyframe_times").widget == .numberList)
        #expect(field(generate.fields, "size").widget == .size(minimum: 16))
        #expect(field(generate.fields, "audio").widget == .toggle)
        #expect(NumberListEditor.parse("0.5, 1.25 2") == [0.5, 1.25, 2] && NumberListEditor.parse(" ") == nil)
        #expect(NumberListEditor.text([0.5, 2]) == "0.5, 2")
        #expect(Set(generate.mediaInputs.map(\.name)) == ["first_frame", "last_frame", "keyframes", "soundtrack", "references", "control"])
    }

    @Test("Acceptance: a named model whose users must accept its terms is an issue until accepted, then policy.accepted carries it")
    func acceptance() async throws {
        let engine = try await InProcessEngine.start(engine: MockVideoEngine(), configuration: engineConfig())
        let form = OperationFormModel(descriptor: await videoDescriptor("video.generate"))
        form.text["prompt"] = "a kite over hills"
        form.setValue(["width": 128, "height": 96], at: ["size"])
        form.setValue(0.375, at: ["duration_s"])
        #expect(form.licencesNeedingAcceptance.map(\.spdx) == [MockVideoEngine.communityLicense.spdx])

        // Automatic: nothing pending, no policy sent, and the engine picks the offer this user may use.
        #expect(form.pendingAcceptance == nil && form.request().policy == nil)
        let open = try await engine.run(form.request())
        #expect(open.outcome == .succeeded && open.plan?.model.id == "mock-video-open")

        form.model = "mock-ltx-compact"
        #expect(form.pendingAcceptance?.spdx == MockVideoEngine.communityLicense.spdx)
        #expect(form.issues["model"]?.contains("Accept") == true)
        form.acceptances.accept(MockVideoEngine.communityLicense)
        #expect(form.pendingAcceptance == nil && form.issues["model"] == nil)
        #expect(form.request().policy?.accepted == [MockVideoEngine.communityLicense.spdx])
        let job = try await engine.run(form.request())
        #expect(job.outcome == .succeeded && job.plan?.model.id == "mock-ltx-compact")
        #expect(job.result?.outputs.first?.frames == 9)

        // Acceptances persist where they're kept.
        let defaults = UserDefaults(suiteName: "mes-forms-tests-\(UUID().uuidString)")!
        LicenseAcceptances(defaults: defaults).accept(MockVideoEngine.communityLicense)
        #expect(LicenseAcceptances(defaults: defaults).isAccepted(MockVideoEngine.communityLicense))
        await engine.stop()
    }

    @Test("Video forms run with a clip: extend, retake, upscale and interpolate, each output with its facts")
    func formsRun() async throws {
        let engine = try await InProcessEngine.start(engine: MockVideoEngine(), configuration: engineConfig())
        let clip = try await clipFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        for (op, params) in [("video.extend", ["after_s": JSONValue.number(0.34)]), ("video.retake", ["start_s": 0.4, "end_s": 0.7]),
                             ("video.upscale", ["content": "drawn"]), ("video.interpolate", ["factor": 2])] {
            let form = OperationFormModel(descriptor: await videoDescriptor(op))
            form.acceptances.accept(MockVideoEngine.communityLicense)
            for spec in form.textInputs { form.text[spec.name] = "a kite" }
            for (name, value) in params { form.setValue(value, at: [name]) }
            form.setValue("draft", at: ["quality"])
            let upload = try await engine.upload(contentsOf: clip, mediaType: MediaType.infer(clip))
            #expect(form.missingInputs(media: ["video"]).isEmpty)
            let job = try await engine.run(form.request(media: ["video": .one(.upload(upload.uploadID))]))
            #expect(job.outcome == .succeeded, "\(op): \(String(describing: job.error))")
            let out = try #require(job.result?.outputs.first)
            #expect(VideoFacts(output: out)?.frames == out.frames && out.frames != nil, "\(op)")
            _ = try? await engine.confirm(job.id)
        }
        #expect(MediaType.infer(URL(fileURLWithPath: "/x/clip.m4v")) == "video/mp4")
        #expect(MediaType.infer(URL(fileURLWithPath: "/x/clip.mov")) == "video/quicktime")
        await engine.stop()
    }

    @Test("FramePreviews collects a running job's stills in time order; a clip's facts and thumbnails read from the file")
    func previewsAndFacts() async throws {
        let engine = try await InProcessEngine.start(engine: MockVideoEngine(), configuration: engineConfig())
        let request = JobRequest(operation: "video.generate", inputs: ["prompt": .text("a kite")],
                                 params: ["size": ["width": 128, "height": 128], "duration_s": 0.375], model: "mock-ltx-standard",
                                 policy: Policy(accepted: [MockVideoEngine.communityLicense.spdx]))
        let job = try await engine.run(request)
        #expect(job.outcome == .succeeded)
        let previews = FramePreviews(output: "video")
        for try await event in engine.events(job: job.id, after: 0) {
            previews.ingest(event)
            if event.type == .outputReady { break }
        }
        #expect(previews.frames.count == 1 && previews.frames.first?.frame == 4)
        #expect(abs((previews.frames.first?.atSeconds ?? 0) - 4.0 / 24) < 1e-9 && NSImage(data: previews.frames[0].image) != nil)

        let clip = try await clipFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        let facts = try await VideoFacts.read(clip)
        #expect(facts.width == 128 && facts.height == 96 && facts.frames == 17 && facts.sampleRate == 48_000 && facts.channels == 2)
        #expect(facts.line.hasPrefix("128×96 · 24 fps · 17 frames") && facts.line.hasSuffix("sound 48 kHz stereo"))
        let thumbs = try await FrameThumbnails.make(clip, count: 4)
        #expect(thumbs.count == 4 && thumbs.map(\.atSeconds) == thumbs.map(\.atSeconds).sorted())
        #expect(VideoFacts(width: 64, height: 64, fps: 23.976, durationSeconds: 1).line.contains("silent"))
        await engine.stop()
    }

    @Test("The video views render: the input well with a clip, the player, a preview strip, the acceptance, the generate form")
    func views() async throws {
        let clip = try await clipFile()
        defer { try? FileManager.default.removeItem(at: clip) }
        let d = await videoDescriptor("video.upscale")
        let spec = d.inputs.first { $0.kind == .video }!
        #expect(render(VideoInputWell(spec: spec, file: .constant(clip))).height > 40)
        #expect(render(VideoInputWell(spec: spec, file: .constant(nil))).height > 20)
        #expect(render(VideoPlayerView(file: clip, title: "Upscaled", facts: VideoFacts(width: 256, height: 192, fps: 24, frames: 17,
                                                                                          durationSeconds: 17.0 / 24))).height > 60)
        let still = Clips.encode(Clips.synthetic(width: 64, height: 36, color: (10, 20, 30), t: 0.5), width: 64, height: 36)!
        #expect(render(FramePreviewStrip(frames: [FramePreview(atSeconds: 0.2, frame: 5, image: still)])).height > 20)
        #expect(render(LicenseAcceptanceView(license: MockVideoEngine.communityLicense, title: "Mock LTX", acceptances: LicenseAcceptances())).height > 30)
        let form = OperationFormModel(descriptor: await videoDescriptor("video.generate"))
        form.model = "mock-ltx-standard"
        #expect(render(OperationFormContent(form: form) { spec in
            if spec.kind == .video { VideoInputWell(spec: spec, file: .constant(nil)) } else { MediaSlotPlaceholder(spec: spec) }
        }, width: 480).height > 200)
    }
}
