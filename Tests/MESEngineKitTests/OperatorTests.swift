import Foundation
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

/// The mock engine behind an enabled set: what an engine that honours `ModelEnablement` does in `descriptors()`.
struct EnabledSetEngine: MediaEngine {
    let inner: MockImageEngine
    let enablement: ModelEnablement

    func descriptors() async -> [Descriptor] {
        await inner.descriptors().compactMap { descriptor in
            var d = descriptor
            d.models = d.models.filter { enablement.isEnabled($0.id, optIn: $0.namedOnly == true) }
            return d.models.isEmpty ? nil : d
        }
    }

    func run(_ context: RunContext) async throws -> RunOutput { try await inner.run(context) }
}

@Suite("The operator's API: every client's jobs, operator cancel, the enabled set")
struct OperatorTests {
    @Test("Activity lists the running job, then the queue in slot order, then finished jobs; the operator cancels any of them")
    func activityAndCancel() async throws {
        let config = freshConfig()
        let server = MESEngineServer(engine: MockImageEngine(stepDelay: .milliseconds(150), steps: 20), configuration: config)
        try await server.makeApplication().test(.live) { client in
            let png = try pngData(width: 8, height: 8) { _, _ in (9, 9, 9, 255) }
            let image: [String: RequestInput] = ["image": .one(.inline(mediaType: "image/png", data: png))]
            let slow = try decode(Job.self, try await client.post("/jobs", JobRequest(operation: "image.restore", inputs: image)).body)
            let first = try decode(Job.self, try await client.post("/jobs", JobRequest(operation: "image.generate",
                inputs: ["prompt": .text("a lighthouse\nat dusk")])).body)
            let second = try decode(Job.self, try await client.post("/jobs", JobRequest(operation: "image.score", inputs: image)).body)
            try await Task.sleep(for: .milliseconds(400))

            var updates = server.activity().makeAsyncIterator()
            let snapshot = try #require(await updates.next())
            #expect(snapshot.running.map(\.id) == [slow.id])
            #expect(snapshot.upcoming.map(\.id) == [first.id, second.id])
            #expect(snapshot.upcoming.map(\.queuePosition) == [1, 2])
            #expect(snapshot.upcoming.first?.summary == "a lighthouse at dusk")
            #expect(snapshot.running.first?.startedAt != nil && snapshot.running.first?.client == "local")

            let cancelled = try await server.cancel(job: first.id)
            #expect(cancelled.state == .purged && cancelled.outcome == .cancelled)
            try await server.cancel(job: slow.id)
            var after = server.activity().makeAsyncIterator()
            var latest = try #require(await after.next())
            for _ in 0..<200 where latest.running.first?.id != second.id {
                latest = try #require(await after.next())
            }
            #expect(latest.running.first?.id == second.id, "the slot passed to the job behind the cancelled ones")
            #expect(Set(latest.finished.map(\.id)) == [first.id, slow.id])
            #expect(latest.finished.allSatisfy { $0.outcome == .cancelled && $0.finishedAt != nil })
            await #expect(throws: MESError.self) { try await server.cancel(job: "job_missing") }
        }
    }

    @Test("Switching a model off drops it from the offers; a reload announces operations_changed with the new ETag")
    func enabledSet() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("enablement-\(UUID().uuidString).json")
        let enablement = ModelEnablement(file: file)
        #expect(enablement.isEnabled("mock", optIn: false))
        #expect(!enablement.isEnabled("mock-research", optIn: true), "opt-in models start off")

        let server = MESEngineServer(engine: EnabledSetEngine(inner: MockImageEngine(), enablement: enablement),
                                     configuration: freshConfig())
        try await server.makeApplication().test(.live) { client in
            let before = try #require(await server.operations())
            #expect(!before.flatMap(\.models).contains { $0.id == "mock-research" })
            let etag = try #require(try await client.get("/operations").headers[.eTag])

            try enablement.set("mock-research", enabled: true, optIn: true)
            #expect(enablement.acceptedAt("mock-research") != nil)
            await server.reloadDescriptors()
            let after = try #require(await server.operations())
            #expect(after.flatMap(\.models).contains { $0.id == "mock-research" && $0.namedOnly == true })
            #expect(try await client.get("/operations").headers[.eTag] != etag)

            try enablement.set("mock", enabled: false, optIn: false)
            await server.reloadDescriptors()
            let none = try #require(await server.operations())
            #expect(!none.flatMap(\.models).contains { $0.id == "mock" })
            let named = try await client.post("/jobs", JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                                   model: "mock"))
            #expect(try client.errorCode(named) == "model_unavailable", "a model that's off can't be named")
        }
        let reloaded = ModelEnablement(file: file)
        #expect(reloaded.choices.disabled == ["mock"] && reloaded.choices.enabled == ["mock-research"])
        try enablement.set("mock-research", enabled: false, optIn: true)
        #expect(ModelEnablement(file: file).acceptedAt("mock-research") == nil)
    }

    @Test("Subscribers to \"*\" hear engine.operations_changed when a reload changes the list")
    func operationsChangedEvent() async throws {
        let enablement = ModelEnablement(file: nil)
        let config = freshConfig()
        let server = MESEngineServer(engine: EnabledSetEngine(inner: MockImageEngine(), enablement: enablement),
                                     configuration: config)
        _ = try await server.makeApplication()
        // The registry's owner subscription is what the WebSocket's "*" forwards.
        try enablement.set("mock-research", enabled: true, optIn: true)
        let registry = JobRegistry(engine: EnabledSetEngine(inner: MockImageEngine(), enablement: enablement), config: config,
                                   spool: try Spool.prepare(at: config.spoolDirectory).0)
        await registry.start()
        var events = await registry.subscribeAll(owner: "local").makeAsyncIterator()
        try enablement.set("mock-research", enabled: false, optIn: true)
        await registry.reloadDescriptors()
        let event = try #require(await events.next())
        #expect(event.type == .operationsChanged && event.job == nil)
        #expect(event.data["etag"]?.stringValue == (await registry.operationsList.etag))
        await registry.stop()
    }
}
