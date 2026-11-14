import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// AB-A-0260 (Craft Anything, Gaea's first real client): the registry reports the time a job spends in stage preparing as
// prepare_ms (Base §10.1), and an engine fills the idle policy, resident_until and x- members on GET /health (§14).

/// What the engine itself saw of one run, in milliseconds on the registry's clock: from just before it first said
/// `preparing` to just after it said `running` (the registry's own measure lies inside that), and from there to the
/// end of its run.
actor RunTimes {
    private(set) var preparing: Double?
    private(set) var running: Double?
    func record(preparing: Double, running: Double) { self.preparing = preparing; self.running = running }
}

/// The image mock, preparing for a while before it runs (a download, then a load), and saying how long it keeps models.
struct PreparingEngine: MediaEngine {
    let mock = MockImageEngine()
    let preparing: Duration
    var times = RunTimes()
    func descriptors() async -> [Descriptor] { await mock.descriptors() }
    func run(_ context: RunContext) async throws -> RunOutput {
        let began = Date()
        if preparing > .zero {
            await context.reporter.progress(.preparing, message: "downloading the weights (first use): 4.2 of 19.0 GB")
            try await Task.sleep(for: preparing / 2)
            await context.reporter.progress(.preparing, message: "loading the model")
            try await Task.sleep(for: preparing / 2)
        }
        await context.reporter.progress(.running, phase: "denoise", step: 1, steps: 1)
        let prepared = Date()
        try await Task.sleep(for: .milliseconds(100))
        let output = try await mock.run(context)
        await times.record(preparing: prepared.timeIntervalSince(began) * 1000, running: Date().timeIntervalSince(prepared) * 1000)
        return output
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
    func app(_ preparing: Duration, times: RunTimes = RunTimes()) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: PreparingEngine(preparing: preparing, times: times), configuration: freshConfig()).makeApplication()
    }

    static let generate = JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")])

    // No bound here depends on how fast the machine is: a sleep never ends early, the registry stamps `preparing`
    // inside the engine's own awaited reports, and the job's times fit inside the client's wait for it. A loaded CI runner stretched the 0.6 s of
    // preparing past the 1.5 s this test once allowed (the v0.13.0 run).
    @Test("A job that reported preparing reports prepare_ms, and run_ms is the rest")
    func prepareMs() async throws {
        let times = RunTimes()
        try await app(.milliseconds(600), times: times).test(.live) { client in
            let submitted = Date()
            let job = try await client.run(Self.generate)
            let elapsed = Date().timeIntervalSince(submitted) * 1000
            #expect(job.outcome == .succeeded, "\(job.error?.message ?? "")")
            let t = try #require(job.result?.provenance.timings)
            let prepare = Double(try #require(t.prepareMs)), run = Double(try #require(t.runMs))
            let seen = try #require(await times.preparing), after = try #require(await times.running)
            let slack = 5.0                                                   // rounding to whole milliseconds
            // prepare_ms covers both sleeps, and no more than the engine itself spent saying `preparing`.
            #expect(prepare >= 600 - slack && prepare <= seen + slack, "prepare_ms \(prepare); the engine saw \(seen)")
            // run_ms is the rest: at least the run after preparing, which the engine timed too.
            #expect(run >= 100 - slack && run >= after - slack, "run_ms \(run); the engine ran \(after) after preparing")
            // And it doesn't count the preparing twice: waiting, preparing and running fit between this client sending
            // the job and seeing it finished. (The job's own timestamps are whole seconds on the wire: too coarse.)
            let queue = Double(t.queueMs ?? 0)
            #expect(queue + prepare + run <= elapsed + slack,
                    "queue \(queue) + prepare \(prepare) + run \(run) exceed the \(elapsed) ms the job took, seen from here")
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
