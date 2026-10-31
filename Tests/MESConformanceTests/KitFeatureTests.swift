import CryptoKit
import Foundation
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import MockEngineCore
import Testing

// MESEngineKit's halves of RFCs 0001–0003 that the conformance suite can't reach from outside: how the kit splits and
// holds back chunks, what a failed stream leaves, the asset hook, and phase changes inside the progress throttle.

actor Seen {
    var removed: [String] = []
    var assets: [[String: [String?]]] = []
    func remove(_ id: String) { removed.append(id) }
    func add(_ a: [String: [String?]]) { assets.append(a) }
}

/// One `audio.speak` offer that streams awkwardly: a partial frame first, then a final chunk of 600 KB, failing after
/// it when the text says "fail". It reports a phase change inside the throttle interval for "phases".
struct ChunkyEngine: MediaEngine {
    let seen = Seen()
    static let big = Data((0..<600_000).map { UInt8($0 % 251) })

    func descriptors() async -> [Descriptor] {
        var d = MockAudioEngine.descriptor("audio.speak")
        d.models = [ModelOffer(id: "chunky", title: "Chunky", license: .apache2, qualityTiers: [.draft, .standard, .best], isDefault: true,
                               supports: ["stream": true, "voice_ref": true, "default_voice": true, "sample_rate": 24000])]
        return [d]
    }

    func run(_ c: RunContext) async throws -> RunOutput {
        await seen.add(c.assets)
        let text = c.input("text")?.text ?? ""
        if text == "phases" {
            await c.reporter.progress(phase: "plan", step: 1, steps: 3)
            await c.reporter.progress(phase: "decode", step: 1, steps: 2)
        }
        guard c.stream("audio") != nil else {
            let url = c.outputDirectory.appendingPathComponent("a.wav")
            try WAVFile(sampleRate: 24000, channels: 1, samples: [0, 1, 2, 3]).data.write(to: url)
            return RunOutput(outputs: [.audio(url, name: "audio", durationSeconds: 4.0 / 24000, sampleRate: 24000, channels: 1, bitDepth: 16)])
        }
        await c.reporter.chunk("audio", samples: Data([1, 2, 3]))
        await c.reporter.chunk("audio", samples: Self.big + Data([4]), final: true)
        if text == "fail" { throw MESError(.engineError, "failed after streaming") }
        return RunOutput(outputs: [.streamed("audio")])
    }

    func assetRemoved(_ id: String) async { await seen.remove(id) }
}

func chunks(_ frames: [Wire.Frame]) throws -> [Event] {
    try frames.map { try MESJSON.decoder.decode(Event.self, from: Data($0.data.utf8)) }.filter { $0.type == .outputChunk }
}

@Suite("MESEngineKit: streams, assets and progress phases", .serialized)
struct KitFeatureTests {
    func wire(_ port: Int) -> Wire { Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!) }

    @Test("A large final chunk is split into events of at most 256 KiB, a partial frame is carried, and the output is the chunks")
    func splitAndParity() async throws {
        try await serve(mockConfig(), engine: ChunkyEngine()) { port in
            let w = wire(port)
            let request = JobRequest(operation: "audio.speak", inputs: ["text": .text("hello")], stream: [StreamRequest(output: "audio")])
            let job = try await w.json("POST", "jobs", request).decode(Job.self)
            let (_, frames, _) = try await w.frames("jobs/\(job.id)/events", timeout: 20) { $0.event == "job.output_ready" }
            let events = try chunks(frames)
            #expect(events.count == 5, "\(events.count) chunks")
            #expect(events.map { $0.data["index"]?.intValue } == [0, 1, 2, 3, 4])
            #expect(events.allSatisfy { ($0.data["data"]?.stringValue?.count ?? .max) <= 262_144 })
            #expect(events.filter { $0.data["final"]?.boolValue == true }.count == 1 && events.last?.data["final"]?.boolValue == true)
            let pcm = events.compactMap { $0.data["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } }.reduce(Data(), +)
            #expect(pcm == Data([1, 2, 3]) + Self.trimmed)
            let held = try await w.send("GET", "jobs/\(job.id)?wait=10").decode(Job.self)
            let file = try await w.send("GET", "jobs/\(job.id)/outputs/0").body
            #expect(try WAVFile(file).pcm == pcm)
            #expect(held.result?.outputs.first?.durationSeconds == Double(pcm.count / 2) / 24000)
            #expect(held.plan?.streams == [StreamPlan(output: "audio", encoding: .pcmS16LE, sampleRate: 24000, channels: 1)])
        }
    }

    static var trimmed: Data { ChunkyEngine.big + Data([4]) }

    @Test("A job that fails after streaming sends no final chunk, and its chunks keep no samples")
    func failedStream() async throws {
        try await serve(mockConfig(), engine: ChunkyEngine()) { port in
            let w = wire(port)
            let request = JobRequest(operation: "audio.speak", inputs: ["text": .text("fail")], stream: [StreamRequest(output: "audio")])
            let job = try await w.json("POST", "jobs", request).decode(Job.self)
            let (_, frames, _) = try await w.frames("jobs/\(job.id)/events", timeout: 20) { $0.event == "job.ended" }
            let events = try chunks(frames)
            #expect(!events.isEmpty)
            #expect(!events.contains { $0.data["final"]?.boolValue == true })
            #expect(events.allSatisfy { $0.data["data"] == nil }, "a failed job's replayed chunks carry no samples")
            #expect(try await w.send("GET", "jobs/\(job.id)").decode(Job.self).outcome == .failed)
        }
    }

    @Test("An asset reaches RunContext.assets by input, two jobs use it, and deleting it calls assetRemoved")
    func assetHook() async throws {
        let engine = ChunkyEngine()
        try await serve(mockConfig(), engine: engine) { port in
            let w = wire(port)
            let clip = Fixtures.wav()
            let digest = Data(SHA256.hash(data: clip)).base64EncodedString()
            let asset = try await w.send("POST", "assets?ttl_s=120", headers: ["Content-Type": "audio/wav", "Content-Digest": "sha-256=:\(digest):"],
                                         body: clip).decode(Asset.self)
            for _ in 0..<2 {
                let r = JobRequest(operation: "audio.speak", inputs: ["text": .text("hi"), "voice_ref": .one(.asset(asset.assetID))])
                let job = try await w.json("POST", "jobs", r).decode(Job.self)
                _ = try await w.send("GET", "jobs/\(job.id)?wait=10")
            }
            #expect(await engine.seen.assets.map { $0["voice_ref"] } == [[asset.assetID], [asset.assetID]])
            #expect(try await w.send("DELETE", "assets/\(asset.assetID)").status == 204)
            #expect(await engine.seen.removed == [asset.assetID])
            let tooShort = try await w.send("POST", "assets?ttl_s=10", headers: ["Content-Type": "audio/wav"], body: clip)
            #expect(tooShort.status == 400)
        }
    }

    @Test("A new progress phase goes out even inside the throttle interval (AB-A-0156)")
    func phaseChange() async throws {
        try await serve(mockConfig { $0.minProgressInterval = .seconds(5) }, engine: ChunkyEngine()) { port in
            let w = wire(port)
            let r = JobRequest(operation: "audio.speak", inputs: ["text": .text("phases")])
            let job = try await w.json("POST", "jobs", r).decode(Job.self)
            let (_, frames, _) = try await w.frames("jobs/\(job.id)/events", timeout: 20) { $0.event == "job.output_ready" }
            let phases = try frames.map { try MESJSON.decoder.decode(Event.self, from: Data($0.data.utf8)) }
                .filter { $0.type == .progress }.compactMap { $0.data["phase"]?.stringValue }
            #expect(phases == ["plan", "decode"], "\(phases)")
        }
    }

    @Test("Gates route without a named model and refuse a named one; a voice implies its model (the mock's three speak offers)")
    func routing() async throws {
        try await serve(mockConfig()) { port in
            let w = wire(port)
            func submit(_ r: JobRequest) async throws -> Wire.Reply { try await w.json("POST", "jobs", r) }
            let clip = RequestInput.one(.inline(mediaType: "audio/wav", data: Fixtures.wav()))
            // A clone with an emotion only mock-clone lists, at the default tier, goes there.
            let clone = try await submit(JobRequest(operation: "audio.speak", inputs: ["text": .text("hi"), "voice_ref": clip],
                                                    params: ["emotion": ["label": "scared"]]))
            #expect(clone.status == 201)
            let cloned = try clone.decode(Job.self)
            #expect(try await w.send("GET", "jobs/\(cloned.id)?wait=10").decode(Job.self).plan?.model.id == "mock-clone")
            #expect(try await w.send("GET", "jobs/\(cloned.id)").decode(Job.self).plan?.effective["emotion"]?["label"] == "afraid")
            // Named: refused, never substituted.
            let named = try await submit(JobRequest(operation: "audio.speak", inputs: ["text": .text("hi"), "voice_ref": clip], model: "mock-presets"))
            #expect(named.status == 422 && named.errorCode == "unsupported_parameter" && named.json?["error"]?["param"] == "voice_ref")
            // The research offer needs the transcript, and is never chosen by default anyway.
            let research = try await submit(JobRequest(operation: "audio.speak", inputs: ["text": .text("hi"), "voice_ref": clip],
                                                       model: "mock-clone-research"))
            #expect(research.status == 422 && research.json?["error"]?["param"] == "voice_ref_text")
            // A text over the offer's limit is out_of_limits.
            let long = try await submit(JobRequest(operation: "audio.speak", inputs: ["text": .text(String(repeating: "a", count: 2500))],
                                                   params: ["voice": "mock-alto"], model: "mock-presets"))
            #expect(long.status == 422 && long.errorCode == "out_of_limits")
        }
    }
}
