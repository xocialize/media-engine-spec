import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// AB-A-0260 (Craft Anything, Gaea's first real client): the registry reports the time a job spends in stage preparing as
// prepare_ms (Base §10.1), and an engine fills the idle policy, resident_until and x- members on GET /health (§14).

/// The image mock, preparing for a while before it runs (a download, then a load), and saying how long it keeps models.
struct PreparingEngine: MediaEngine {
    let mock = MockImageEngine()
    let preparing: Duration
    func descriptors() async -> [Descriptor] { await mock.descriptors() }
    func run(_ context: RunContext) async throws -> RunOutput {
        if preparing > .zero {
            await context.reporter.progress(.preparing, message: "downloading the weights (first use): 4.2 of 19.0 GB")
            try await Task.sleep(for: preparing / 2)
            await context.reporter.progress(.preparing, message: "loading the model")
            try await Task.sleep(for: preparing / 2)
        }
        await context.reporter.progress(.running, phase: "denoise", step: 1, steps: 1)
        try await Task.sleep(for: .milliseconds(100))
        return try await mock.run(context)
    }
    func residentModels() async -> [String] { ["mock-turbo"] }
    func health(_ kit: Health) async -> Health {
        var h = kit
        h.memory = .init(headroomBytes: 8 << 30, memoryClass: .large, idleUnloadSeconds: 900)
        h.residentUntil = ["mock-turbo": Date(timeIntervalSince1970: 1_800_000_000)]
        h.extensions = ["x-gaea.workers": 2]
        return h
    }
}

@Suite("prepare_ms and the idle policy (AB-A-0260)")
struct PrepareAndHealthTests {
    func app(_ preparing: Duration) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: PreparingEngine(preparing: preparing), configuration: freshConfig()).makeApplication()
    }

    static let generate = JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")])

    @Test("A job that reported preparing reports prepare_ms, and run_ms is the rest")
    func prepareMs() async throws {
        try await app(.milliseconds(600)).test(.live) { client in
            let job = try await client.run(Self.generate)
            #expect(job.outcome == .succeeded, "\(job.error?.message ?? "")")
            let t = try #require(job.result?.provenance.timings)
            let prepare = try #require(t.prepareMs), run = try #require(t.runMs)
            #expect(prepare >= 550 && prepare < 1500, "prepare_ms \(prepare)")
            #expect(run >= 90 && run < prepare, "run_ms \(run) should be the run after preparing")
            #expect(conforms(try await client.get("/jobs/\(job.id)").body, to: "base/job.schema.json").isEmpty)
        }
    }

    @Test("A job that never reported preparing has no prepare_ms")
    func noPrepare() async throws {
        try await app(.zero).test(.live) { client in
            let t = try #require(try await client.run(Self.generate).result?.provenance.timings)
            #expect(t.prepareMs == nil && t.runMs != nil)
        }
    }

    @Test("GET /health carries the engine's idle policy, resident_until and x- members, and validates")
    func health() async throws {
        try await app(.zero).test(.live) { client in
            let r = try await client.get("/health")
            #expect(conforms(r.body, to: "base/health.schema.json").isEmpty)
            let h = try decode(Health.self, r.body)
            #expect(h.memory?.idleUnloadSeconds == 900 && h.residentModels == ["mock-turbo"])
            #expect(h.residentUntil?["mock-turbo"] == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(h.extensions == ["x-gaea.workers": 2])
            let raw = try decode(JSONValue.self, r.body)
            #expect(raw["x-gaea.workers"] == 2 && raw["memory"]?["idle_unload_s"] == 900)
        }
    }
}
