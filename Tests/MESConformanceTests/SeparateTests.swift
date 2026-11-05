import Foundation
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import MockEngineCore
import Testing

// RFC 0006 in the kit, against the mock engine over HTTP: audio.separate's 400s, its stem and speaker-pick gates and
// routing, the stems a plan reports, stem outputs; edit_speech's cue placement, removing every cue, an edit fitted to a
// length and dereverb; and a separator that breaks AUDIO-015 failing exactly it.

/// A separator whose regenerated stems are a second long, whatever the mixture: AUDIO-015 must catch it.
struct ShortStemsEngine: MediaEngine {
    func descriptors() async -> [Descriptor] { [MockAudioEngine.descriptor("audio.separate")] }

    func run(_ context: RunContext) async throws -> RunOutput {
        let mixture = try WAVFile(Data(contentsOf: context.input("audio")!.fileURL!))
        if let max = context.model.limits?.maxDurationSeconds, mixture.durationSeconds > max {
            throw MESError(.outOfLimits, "The mixture is too long.", param: "audio")
        }
        let outputs = try context.stems.map { stem -> ProducedOutput in
            let url = context.outputDirectory.appendingPathComponent("\(stem).wav")
            try Fixtures.wav(seconds: 1).write(to: url)
            return .audio(url, name: stem, durationSeconds: 1, sampleRate: 24000, channels: 1, bitDepth: 16)
        }
        return RunOutput(outputs: outputs, effective: ["stems": .array(context.stems.map { .string($0) })], seed: 1)
    }
}

@Suite("RFC 0006 in the kit: separation and AuK's edits", .serialized)
struct SeparateKitTests {
    static let clip = RequestInput.one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
    func wire(_ port: Int) -> Wire { Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!) }

    @Test("separate: stems route by what offers make; a pick routes by its kind; the plan names the stems; bad requests are 400 or 422")
    func separate() async throws {
        try await serve(mockConfig()) { port in
            let w = wire(port)
            func submit(_ params: [String: JSONValue], model: String? = nil) async throws -> Wire.Reply {
                try await w.json("POST", "jobs", JobRequest(operation: "audio.separate", inputs: ["audio": Self.clip], params: params, model: model))
            }
            func held(_ reply: Wire.Reply) async throws -> Job {
                try await w.send("GET", "jobs/\(try reply.decode(Job.self).id)?wait=10").decode(Job.self)
            }
            // No stems: the default offer's, which the plan names; one output per stem, the mixture's length.
            let all = try await held(try await submit([:]))
            #expect(all.plan?.model.id == "mock-separator" && all.plan?.effective["stems"] == ["vocals", "instrumental"])
            #expect(all.result?.outputs.map(\.name) == ["vocals", "instrumental"])
            #expect(all.result?.stems.map(\.stem) == ["vocals", "instrumental"])
            #expect(all.result?.outputs.allSatisfy { abs(($0.durationSeconds ?? 0) - 2) < 0.001 && $0.channels == 2 } == true)
            // A pick by words routes to the one pickable offer that makes the speaker; by order, none may: 422 on speaker.
            let words = try await held(try await submit(["stems": ["speaker"], "speaker": ["saying": "hello there"]]))
            #expect(words.plan?.model.id == "mock-separator-flash" && words.result?.outputs.map(\.name) == ["speaker"])
            #expect(words.result?.effective["speaker"] == ["saying": "hello there"])
            // (At draft, where the one pickable speaker offer is; with no tier the kit reports the default tier's refusal.)
            let order = try await submit(["stems": ["speaker"], "speaker": ["ordinal": 2], "quality": "draft"])
            #expect(order.status == 422 && order.errorCode == "unsupported_parameter" && order.json?["error"]?["param"] == "speaker")
            // Named, by order: the voices offer takes it; a pick alone means just the speaker.
            let named = try await held(try await submit(["speaker": ["ordinal": 2]], model: "mock-separator-voices"))
            #expect(named.result?.outputs.map(\.name) == ["speaker"] && named.plan?.effective["stems"] == ["speaker"])
            // A stem the named offer doesn't make: 422 on stems, never another offer.
            let unmade = try await submit(["stems": ["singing"]], model: "mock-separator")
            #expect(unmade.status == 422 && unmade.errorCode == "unsupported_parameter" && unmade.json?["error"]?["param"] == "stems")
            // 400s: a stem twice; the speaker stem without a pick; a pick with stems that don't name it.
            for params: [String: JSONValue] in [["stems": ["vocals", "vocals"]], ["stems": ["speaker"]],
                                                ["stems": ["vocals"], "speaker": ["saying": "hi"]]] {
                let bad = try await submit(params)
                #expect(bad.status == 400 && bad.errorCode == "invalid_request", "\(params)")
            }
            // Two pick kinds at once fail the schema.
            let both = try await submit(["stems": ["speaker"], "speaker": ["ordinal": 1, "saying": "hi"]], model: "mock-separator-voices")
            #expect(both.status == 422 || both.status == 400)
            // A mixture over the offer's 30 s fails the job out_of_limits.
            let long = try await w.json("POST", "jobs", JobRequest(operation: "audio.separate",
                                                                    inputs: ["audio": .one(.inline(mediaType: "audio/wav", data: Fixtures.wav(seconds: 31, rate: 8000)))],
                                                                    params: ["stems": ["singing"]], model: "mock-separator-voices"))
            let failed = try await held(long)
            #expect(failed.outcome == .failed && failed.error?.code == "out_of_limits")
        }
    }

    @Test("edit_speech: cue placement, removing every cue and target_duration_s are gated; a fitted take is that long; dereverb and hum run")
    func edits() async throws {
        try await serve(mockConfig()) { port in
            let w = wire(port)
            func submit(_ edit: JSONValue, _ extra: [String: JSONValue] = [:], model: String = "mock-editor-research") async throws -> Wire.Reply {
                var params = extra
                params["edit"] = edit
                return try await w.json("POST", "jobs", JobRequest(operation: "audio.edit_speech", inputs: ["audio": Self.clip],
                                                                   params: params, model: model))
            }
            func held(_ reply: Wire.Reply) async throws -> Job {
                try await w.send("GET", "jobs/\(try reply.decode(Job.self).id)?wait=10").decode(Job.self)
            }
            let inline = try await submit(["kind": "add_cue", "cue": "hum", "text": "Hello [hum] there."])
            #expect(inline.status == 422 && inline.errorCode == "unsupported_parameter" && inline.json?["error"]?["param"] == "edit")
            #expect(try await held(try await submit(["kind": "add_cue", "cue": "hum", "at": "start"])).outcome == .succeeded)
            let every = try await submit(["kind": "remove_cue"])
            #expect(every.status == 422 && every.errorCode == "unsupported_parameter")
            #expect(try await held(try await submit(["kind": "remove_cue", "cue": "laugh"])).outcome == .succeeded)
            #expect(try await held(try await submit(["kind": "dereverb"])).outcome == .succeeded)
            let extra = try await submit(["kind": "dereverb", "factor": 2])
            #expect(extra.status == 400 && extra.errorCode == "invalid_request")
            // Fitted to 1.25 s; the default editor can't fit, and 40 s is past the offer's 30 s.
            let fitted = try await held(try await submit(["kind": "replace_text", "text": "Hello", "with": "Hi there"], ["target_duration_s": 1.25]))
            #expect(abs((fitted.result?.outputs.first?.durationSeconds ?? 0) - 1.25) < 0.001)
            let cannot = try await submit(["kind": "denoise"], ["target_duration_s": 1.25], model: "mock-editor")
            #expect(cannot.status == 422 && cannot.json?["error"]?["param"] == "target_duration_s")
            let tooLong = try await submit(["kind": "denoise"], ["target_duration_s": 40])
            #expect(tooLong.status == 422 && tooLong.errorCode == "out_of_limits")
        }
    }

    @Test("A separator whose stems aren't the mixture's length fails AUDIO-015 and nothing else it's asked")
    func catchesShortStems() async throws {
        try await serve(mockConfig(), engine: ShortStemsEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ["AUDIO-001", "AUDIO-002", "AUDIO-003", "AUDIO-015", "AUDIO-016", "AUDIO-017"])
            let failed = Set(report.results.filter { $0.status == .fail }.map(\.id))
            #expect(failed == ["AUDIO-015"], "\(failures(report))")
        }
    }
}
