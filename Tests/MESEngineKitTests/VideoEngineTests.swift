import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// Video 0.1 and RFC 0005 in the kit: VideoProfileRules (400s, gates, limits, warnings), users' acceptance (Base §10.3),
// output frames and audio facts, frame previews, and the MCP model lines, against the mock video engine over HTTP.

@Suite("Video 0.1 in the kit")
struct VideoEngineTests {
    func app(_ config: EngineConfiguration = freshConfig()) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: MockVideoEngine(), configuration: config).makeApplication()
    }

    static let accepted = Policy(accepted: [MockVideoEngine.communityLicense.spdx])
    static let small: [String: JSONValue] = ["size": ["width": 128, "height": 96], "duration_s": 0.375, "fps": 24, "seed": 3]

    static func clip(frames: Int = 17, audio: Bool = true) async throws -> RequestInput {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vet-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Clips.write(VideoClipTests.clip(frames: frames, audio: audio), to: url)
        return .one(.inline(mediaType: "video/mp4", data: try Data(contentsOf: url)))
    }

    @Test("generate: frames on the 8k + 1 grid, a snapped size warns, output facts and effective agree, the job validates")
    func generate() async throws {
        try await app().test(.live) { client in
            var params = Self.small
            params["size"] = ["width": 120, "height": 96]
            params["quality"] = "draft"                      // the default tier is standard, which the two-stage offer serves
            let job = try await client.run(JobRequest(operation: "video.generate", inputs: ["prompt": .text("a kite")], params: params,
                                                      policy: Self.accepted))
            #expect(job.outcome == .succeeded && job.plan?.model.id == "mock-ltx-compact")
            let out = try #require(job.result?.outputs.first)
            #expect(out.kind == .video && out.frames == 9 && out.fps == 24 && out.width == 128 && out.height == 96)
            #expect(out.sampleRate == 48_000 && out.channels == 2 && out.hasAudioTrack)
            #expect(job.warnings.map(\.code).contains("size_snapped"))
            #expect(job.result?.effective["frames"] == 9 && job.result?.effective["audio"] == true)
            let held = try await client.get("/jobs/\(job.id)")
            #expect(conforms(held.body, to: "base/job.schema.json").isEmpty)
        }
    }

    @Test("Users' acceptance: a named offer without it is policy_unmet terms_not_accepted; unnamed, the engine picks an offer the user may use")
    func acceptance() async throws {
        try await app().test(.live) { client in
            let request = JobRequest(operation: "video.generate", inputs: ["prompt": .text("a kite")], params: Self.small,
                                     model: "mock-ltx-compact")
            let refused = try await client.post("/jobs", request)
            #expect(refused.status == .unprocessableContent)
            let error = try decode(ErrorBody.self, refused.body).error
            #expect(error.code == "policy_unmet" && error.reason == "terms_not_accepted" && error.param == "policy")
            #expect(error.message.contains("LicenseRef-Mock-Video-Community") && conforms(refused.body, to: "base/error.schema.json").isEmpty)

            var unnamed = request
            unnamed.model = nil
            unnamed.params?["quality"] = "draft"
            let open = try await client.run(unnamed)
            #expect(open.outcome == .succeeded && open.plan?.model.id == "mock-video-open", "the open offer serves a user who accepted nothing")

            var withTerms = request
            withTerms.policy = Self.accepted
            #expect(try await client.run(withTerms).plan?.model.id == "mock-ltx-compact")

            // Only the community offers serve best: without acceptance, nothing may.
            var best = unnamed
            best.params?["quality"] = "best"
            let none = try await client.post("/jobs", best)
            #expect(try decode(ErrorBody.self, none.body).error.reason == "terms_not_accepted")
        }
    }

    @Test("Rules: 400 for size with aspect, keyframes without times, a time outside the clip, a reversed span, factor with fps, no content")
    func structure() async throws {
        try await app().test(.live) { client in
            func code(_ op: String, _ inputs: [String: RequestInput], _ params: [String: JSONValue], model: String? = nil) async throws -> String {
                let r = try await client.post("/jobs", JobRequest(operation: op, inputs: inputs, params: params, model: model, policy: Self.accepted))
                return r.status == .created ? "created" : try client.errorCode(r)
            }
            let png = RequestInput.one(.inline(mediaType: "image/png", data: try pngData(width: 8, height: 8) { _, _ in (1, 2, 3, 255) }))
            let clip = try await Self.clip()
            let prompt = RequestInput.text("x")
            var p = Self.small
            p["aspect"] = "16:9"
            #expect(try await code("video.generate", ["prompt": prompt], p) == "invalid_request")
            #expect(try await code("video.generate", ["prompt": prompt, "keyframes": png], Self.small, model: "mock-ltx-standard") == "invalid_request")
            p = Self.small
            p["keyframe_times"] = [1.0]
            #expect(try await code("video.generate", ["prompt": prompt, "keyframes": png], p, model: "mock-ltx-standard") == "invalid_request")
            #expect(try await code("video.generate", ["prompt": prompt], ["resolution": 288]) == "invalid_request")
            #expect(try await code("video.retake", ["video": clip, "prompt": prompt], ["start_s": 0.5, "end_s": 0.2]) == "invalid_request")
            #expect(try await code("video.extend", ["video": clip, "prompt": prompt], ["after_s": 0]) == "invalid_request")
            #expect(try await code("video.interpolate", ["video": clip], ["factor": 2, "fps": 48]) == "invalid_request")
            #expect(try await code("video.upscale", ["video": clip], ["scale": 2]) == "invalid_request")
        }
    }

    @Test("Gates and limits: an input, mode or content a named offer lacks is 422 unsupported_parameter; a size or factor over its limit is out_of_limits")
    func gates() async throws {
        try await app().test(.live) { client in
            func code(_ op: String, _ inputs: [String: RequestInput], _ params: [String: JSONValue], model: String? = nil) async throws -> String {
                let r = try await client.post("/jobs", JobRequest(operation: op, inputs: inputs, params: params, model: model, policy: Self.accepted))
                return r.status == .created ? "created" : try client.errorCode(r)
            }
            let png = RequestInput.one(.inline(mediaType: "image/png", data: try pngData(width: 8, height: 8) { _, _ in (1, 2, 3, 255) }))
            let clip = try await Self.clip()
            let prompt = RequestInput.text("x")
            #expect(try await code("video.generate", ["prompt": prompt, "last_frame": png], Self.small, model: "mock-ltx-compact") == "unsupported_parameter")
            var big = Self.small
            big["size"] = ["width": 1024, "height": 512]
            #expect(try await code("video.generate", ["prompt": prompt], big, model: "mock-ltx-compact") == "out_of_limits")
            var odd = Self.small
            odd["fps"] = 12
            #expect(try await code("video.generate", ["prompt": prompt], odd, model: "mock-video-open") == "unsupported_parameter")
            #expect(try await code("video.generate", ["prompt": prompt], ["audio": true, "duration_s": 0.375], model: "mock-video-open") == "unsupported_parameter")
            #expect(try await code("video.extend", ["video": clip, "prompt": prompt], ["before_s": 0.5], model: "mock-ltx-compact") == "unsupported_parameter")
            #expect(try await code("video.retake", ["video": clip, "prompt": prompt], ["start_s": 0.1, "end_s": 0.3, "retake": "sound"],
                                   model: "mock-video-open") == "unsupported_parameter")
            #expect(try await code("video.upscale", ["video": clip], ["content": "drawn"], model: "mock-flashvsr") == "unsupported_parameter")
            // With no model named, content routes: drawn goes to the offer that takes it.
            let r = try await client.run(JobRequest(operation: "video.upscale", inputs: ["video": clip], params: ["content": "drawn", "quality": "standard"]))
            #expect(r.plan?.model.id == "mock-seedvr2")
        }
    }

    @Test("Transformations keep the source's audio and marking; interpolate makes (N − 1) × factor + 1 frames; previews carry at_s")
    func transformations() async throws {
        try await app().test(.live) { client in
            let clip = try await Self.clip()
            let up = try await client.run(JobRequest(operation: "video.upscale", inputs: ["video": clip], params: ["content": "live_action", "scale": 2]))
            let upOut = try #require(up.result?.outputs.first)
            #expect(upOut.width == 256 && upOut.height == 192 && upOut.frames == 17 && upOut.sampleRate == 48_000)
            let tween = try await client.run(JobRequest(operation: "video.interpolate", inputs: ["video": clip], params: ["factor": 3]))
            let tweenOut = try #require(tween.result?.outputs.first)
            #expect(tweenOut.frames == 49 && tweenOut.fps == 72 && tweenOut.hasAudioTrack)
            let silent = try await client.run(JobRequest(operation: "video.interpolate", inputs: ["video": try await Self.clip(audio: false)], params: [:]))
            #expect(silent.result?.outputs.first?.sampleRate == nil, "a silent source stays silent")
        }
    }

    @Test("A preview reported with a time reaches the event as output, at_s and frame, and validates")
    func previewEvent() async throws {
        try await app().test(.live) { client in
            let job = try await client.run(JobRequest(operation: "video.generate", inputs: ["prompt": .text("a kite")], params: Self.small,
                                                      model: "mock-ltx-standard", policy: Self.accepted))
            #expect(job.outcome == .succeeded)
            _ = try await client.execute(uri: base + "/jobs/\(job.id)/confirm", method: .post)
            let stream = try await client.get("/jobs/\(job.id)/events", headers: [.accept: "text/event-stream"])
            let text = String(buffer: stream.body)
            let frames = text.components(separatedBy: "\n\n").filter { $0.contains("event: job.preview") }
            #expect(frames.count == 1, "\(text.prefix(400))")
            let data = try #require(frames.first?.split(separator: "\n").first { $0.hasPrefix("data: ") }?.dropFirst(6))
            let event = try MESJSON.decoder.decode(JSONValue.self, from: Data(data.utf8))
            #expect(event["data"]?["output"] == "video" && event["data"]?["frame"] == 4 && event["data"]?["at_s"]?.numberValue == 4.0 / 24)
            #expect(conforms(ByteBuffer(string: String(data)), to: "base/event.schema.json").isEmpty)
        }
    }

    @Test("MCP: a model whose users must accept its terms says so, and the policy argument takes accepted")
    func mcpLines() {
        let offer = MockVideoEngine.models("video.generate")[0]
        let line = MCPToolbox.modelLine(offer, notes: true)
        #expect(line.contains("users must accept these terms (https://example.com/mock-video-community-license): pass policy.accepted [\"LicenseRef-Mock-Video-Community\"]"))
        #expect(!MCPToolbox.modelLine(offer).contains("policy.accepted"), "the short line stays short")
    }
}
