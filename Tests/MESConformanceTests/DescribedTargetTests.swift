import Foundation
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import MockEngineCore
import Testing

// RFC 0008 in the kit, against the mock engine over HTTP: audio.separate by description. The description's gate and
// routing, the target and residual stems, spans and their refusals, what the plan and the result report, the
// watermark an offer states; and a separator that ignores spans' limits failing AUDIO-021 alone.

/// A described-sound separator that never checks spans against the mixture: AUDIO-021 must catch it.
struct UncheckedSpansEngine: MediaEngine {
    func descriptors() async -> [Descriptor] { [MockAudioEngine.descriptor("audio.separate")] }

    func run(_ context: RunContext) async throws -> RunOutput {
        let mixture = try WAVFile(Data(contentsOf: context.input("audio")!.fileURL!))
        if let max = context.model.limits?.maxDurationSeconds, mixture.durationSeconds > max {
            throw MESError(.outOfLimits, "The mixture is too long.", param: "audio")
        }
        let outputs = try context.stems.map { stem -> ProducedOutput in
            let url = context.outputDirectory.appendingPathComponent("\(stem).wav")
            try Fixtures.wav(seconds: mixture.durationSeconds).write(to: url)
            return .audio(url, name: stem, durationSeconds: mixture.durationSeconds, sampleRate: 24000, channels: 1, bitDepth: 16)
        }
        var effective: [String: JSONValue] = ["stems": .array(context.stems.map { .string($0) })]
        if let describe = context.describe { effective["describe"] = .string(describe.lowercased()) }
        if !context.spans.isEmpty { effective["spans"] = .array(context.spans.map(\.json)) }
        return RunOutput(outputs: outputs, effective: effective, seed: 1)
    }
}

@Suite("RFC 0008 in the kit: separating a described sound", .serialized)
struct DescribedTargetKitTests {
    static let clip = RequestInput.one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
    func wire(_ port: Int) -> Wire { Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!) }
    func span(_ a: Double, _ b: Double, _ present: Bool) -> JSONValue { ["start_s": .number(a), "end_s": .number(b), "present": .bool(present)] }

    @Test("describe routes to the offer that separates a described sound; the plan and result name target and residual; bad requests are 400 or 422")
    func describe() async throws {
        try await serve(mockConfig()) { port in
            let w = wire(port)
            func submit(_ params: [String: JSONValue], model: String? = nil) async throws -> Wire.Reply {
                try await w.json("POST", "jobs", JobRequest(operation: "audio.separate", inputs: ["audio": Self.clip], params: params, model: model))
            }
            func held(_ reply: Wire.Reply) async throws -> Job {
                try await w.send("GET", "jobs/\(try reply.decode(Job.self).id)?wait=10").decode(Job.self)
            }
            func param(_ reply: Wire.Reply) -> JSONValue? { reply.json?["error"]?["param"] }

            // A description, no model: the one offer with described_target; both stems, the mixture's length, at its rate.
            let both = try await held(try await submit(["describe": "  Dog Barking "]))
            #expect(both.plan?.model.id == "mock-separator-described" && both.plan?.effective["stems"] == ["target", "residual"])
            #expect(both.result?.outputs.map(\.name) == ["target", "residual"])
            #expect(both.result?.stems.map(\.stem) == ["target", "residual"])
            #expect(both.result?.outputs.allSatisfy { abs(($0.durationSeconds ?? 0) - 2) < 0.001 && $0.sampleRate == 48000 } == true)
            // Case and the spaces around it don't count: the model got it folded, and no warning says so.
            #expect(both.result?.describedSound == "dog barking" && both.warnings.allSatisfy { $0.param != "describe" })
            // One of the two, and in the order asked.
            let one = try await held(try await submit(["describe": "speech", "stems": ["residual"]]))
            #expect(one.result?.outputs.map(\.name) == ["residual"])
            let swapped = try await held(try await submit(["describe": "speech", "stems": ["residual", "target"]]))
            #expect(swapped.result?.outputs.map(\.name) == ["residual", "target"])
            // No description, no model: never the described-only offer.
            let plain = try await held(try await submit([:]))
            #expect(plain.plan?.model.id == "mock-separator")

            // 422: a description to an offer without described_target, by name; and the described-only offer without one.
            let ungated = try await submit(["describe": "speech"], model: "mock-separator")
            #expect(ungated.status == 422 && ungated.errorCode == "unsupported_parameter" && param(ungated) == "describe")
            let bare = try await submit([:], model: "mock-separator-described")
            #expect(bare.status == 422 && bare.errorCode == "unsupported_parameter" && param(bare) == "stems")
            #expect(bare.json?["error"]?["message"]?.stringValue?.contains("describe") == true)
            // 400: target or residual without a description; a description beside a labelled stem or a speaker pick.
            let noWords = try await submit(["stems": ["target"]])
            #expect(noWords.status == 400 && noWords.errorCode == "invalid_request" && param(noWords) == "describe")
            let mixed = try await submit(["describe": "speech", "stems": ["target", "vocals"]])
            #expect(mixed.status == 400 && mixed.errorCode == "invalid_request" && param(mixed) == "stems")
            let picked = try await submit(["describe": "speech", "speaker": ["ordinal": 1]])
            #expect(picked.status == 400 && picked.errorCode == "invalid_request" && param(picked) == "speaker")
            // A description of spaces fails the schema.
            let blank = try await submit(["describe": "   "])
            #expect(blank.status == 400 || blank.status == 422)
        }
    }

    @Test("spans run and come back in time order; they need describe and supports.spans; a backwards, overlapping or too-late span is refused")
    func spans() async throws {
        try await serve(mockConfig()) { port in
            let w = wire(port)
            func submit(_ params: [String: JSONValue], model: String? = nil) async throws -> Wire.Reply {
                try await w.json("POST", "jobs", JobRequest(operation: "audio.separate", inputs: ["audio": Self.clip], params: params, model: model))
            }
            func held(_ reply: Wire.Reply) async throws -> Job {
                try await w.send("GET", "jobs/\(try reply.decode(Job.self).id)?wait=10").decode(Job.self)
            }
            // Sent out of order: the plan and the result carry them in time order, and the outputs keep the mixture's length.
            let job = try await held(try await submit(["describe": "speech", "spans": [span(1, 1.5, false), span(0.25, 0.5, true)]]))
            let ordered = [SeparationSpan(start: 0.25, end: 0.5, present: true), SeparationSpan(start: 1, end: 1.5, present: false)]
            #expect(SeparationSpan.list(job.plan?.effective["spans"]) == ordered && job.result?.separationSpans == ordered)
            #expect(job.result?.outputs.allSatisfy { abs(($0.durationSeconds ?? 0) - 2) < 0.001 } == true)
            // The mock's target is silent where a span says the sound isn't.
            let target = try #require(job.result?.output(named: "target"))
            let wav = try WAVFile(try await w.send("GET", "jobs/\(job.id)/outputs/\(target.index)").body)
            #expect(AudioTests.longestSilence(wav) >= 0.45)
            // Spans may touch.
            #expect(try await held(try await submit(["describe": "speech", "spans": [span(0, 0.5, true), span(0.5, 1, false)]])).outcome == .succeeded)

            // 400: spans without a description; a span that ends at or before its start; two that overlap.
            for params: [String: JSONValue] in [["spans": [span(0, 1, true)]],
                                                ["describe": "speech", "spans": [span(1, 1, true)]],
                                                ["describe": "speech", "spans": [span(1, 0.5, true)]],
                                                ["describe": "speech", "spans": [span(0, 1, true), span(0.5, 1.5, false)]]] {
                let bad = try await submit(params)
                #expect(bad.status == 400 && bad.errorCode == "invalid_request" && bad.json?["error"]?["param"] == "spans", "\(params)")
            }
            // A span without 'present' fails the schema.
            let partial = try await submit(["describe": "speech", "spans": [["start_s": 0, "end_s": 1]]])
            #expect(partial.status == 400 || partial.status == 422)
            // Past the end of the 2 s mixture: the job fails out_of_limits on spans, never clipped. A frame over is let through.
            let late = try await held(try await submit(["describe": "speech", "spans": [span(1, 3, true)]]))
            #expect(late.outcome == .failed && late.error?.code == "out_of_limits" && late.error?.param == "spans")
            let edge = try await held(try await submit(["describe": "speech", "spans": [span(1, 2.00001, true)]]))
            #expect(edge.outcome == .succeeded)
        }
    }

    @Test("The rules alone: default stems, the spans gate, and an offer that separates both ways")
    func rules() throws {
        func offer(_ supports: [String: JSONValue]) -> ModelOffer {
            ModelOffer(id: "m", title: "M", license: .apache2, memoryClass: .small, speedClass: .fast, qualityTiers: [.standard], supports: supports)
        }
        let both = offer(["stems": ["vocals", "instrumental", "target", "residual"], "described_target": true, "stem_method": "masked"])
        #expect(AudioProfileRules.stems([:], model: both) == ["vocals", "instrumental"])
        #expect(AudioProfileRules.stems(["describe": "speech"], model: both) == ["target", "residual"])
        #expect(AudioProfileRules.stems(["describe": "speech", "stems": ["residual"]], model: both) == ["residual"])
        let targetOnly = offer(["stems": ["target"], "described_target": true, "stem_method": "regenerated", "watermark": "audioseal"])
        #expect(AudioProfileRules.stems(["describe": "speech"], model: targetOnly) == ["target"])
        #expect(targetOnly.watermark == "audioseal" && both.watermark == nil)
        // spans to an offer that describes but takes none: the requirement names spans.
        let d = MockAudioEngine.descriptor("audio.separate")
        let request = JobRequest(operation: "audio.separate", inputs: ["audio": Self.clip],
                                 params: ["describe": "speech", "spans": [span(0, 1, true)]])
        let unmet = AudioProfileRules.requirements(request, descriptor: d).filter { !$0.admits(both) }
        #expect(unmet.map(\.param) == ["spans"] && unmet.first?.code == .unsupportedParameter)
    }

    @Test("The mock conforms on AUDIO-019 to 021, and a separator that never checks spans against the mixture fails AUDIO-021 alone")
    func catchesUncheckedSpans() async throws {
        let ids: Set<String> = ["AUDIO-001", "AUDIO-002", "AUDIO-015", "AUDIO-016", "AUDIO-019", "AUDIO-020", "AUDIO-021"]
        try await serve(mockConfig()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ids)
            #expect(report.results.filter { $0.status == .fail }.isEmpty, "\(failures(report))")
            #expect(Set(report.results.filter { $0.status == .pass }.map(\.id)) == ids)
        }
        try await serve(mockConfig(), engine: UncheckedSpansEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ids)
            #expect(Set(report.results.filter { $0.status == .fail }.map(\.id)) == ["AUDIO-021"], "\(failures(report))")
        }
    }
}
