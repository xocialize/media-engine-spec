import Foundation
@testable import MESClientKit
import MESCore
import MESEngineKit
@testable import MockEngineCore
import Testing

// The engine picker (Gaea G-19) against two live mock servers that offer different models: each job lands on the
// server that offers its model, residency and queue length break ties, and a pin holds.

/// The mock engine under other model ids, with a chosen set reported resident.
struct RenamedMockEngine: MediaEngine {
    let inner: MockImageEngine
    /// The mock's ids → this server's ids.
    let renames: [String: String]
    var resident: [String] = []

    func descriptors() async -> [Descriptor] {
        await inner.descriptors().map { descriptor in
            var d = descriptor
            d.models = d.models.map { offer in
                var o = offer
                if let id = renames[offer.id] { o.id = id; o.title = id.capitalized }
                return o
            }
            return d
        }
    }

    func run(_ context: RunContext) async throws -> RunOutput { try await inner.run(context) }

    func residentModels() async -> [String] { resident }
}

/// Serves each engine on its own loopback port and runs `body` with the ports, in order.
func withEngines(_ engines: [(id: String, engine: any MediaEngine)], _ body: ([Int]) async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        var ports: [Int] = []
        for (id, engine) in engines {
            let server = MESEngineServer(engine: engine, configuration: freshConfig { $0.id = id; $0.name = id })
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            let app = try await server.makeApplication { port in continuation.yield(port) }
            group.addTask { try await app.runService() }
            var it = stream.makeAsyncIterator()
            guard let port = await it.next() else { return }
            ports.append(port)
        }
        try await body(ports)
        group.cancelAll()
    }
}

func candidate(_ id: String, _ port: Int) -> EngineCandidate {
    EngineCandidate(id: id, name: id, connection: HTTPEngineConnection(baseURL: openURL(port)))
}

func generate(_ model: String? = nil, quality: String? = nil) -> JobRequest {
    JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
               params: quality.map { ["quality": .string($0), "size": ["width": 64, "height": 64]] } ?? ["size": ["width": 64, "height": 64]], model: model)
}

@Suite("EnginePicker: choosing between servers", .serialized)
struct EnginePickerTests {
    @Test("Two servers with different models: each job lands on the server that offers its model")
    func jobsLandByModel() async throws {
        let alpha = RenamedMockEngine(inner: MockImageEngine(), renames: ["mock": "alpha"])
        let beta = RenamedMockEngine(inner: MockImageEngine(), renames: ["mock": "beta"])
        try await withEngines([("eng_alpha", alpha), ("eng_beta", beta)]) { ports in
            let picker = EnginePicker(candidates: [candidate("eng_alpha", ports[0]), candidate("eng_beta", ports[1])])

            for (model, engine) in [("alpha", "eng_alpha"), ("beta", "eng_beta"), ("alpha", "eng_alpha"), ("beta", "eng_beta")] {
                let (chosen, job) = try await picker.run(generate(model))
                #expect(chosen.id == engine)
                #expect(job.outcome == .succeeded, "\(job.error.map { "\($0)" } ?? "")")
                #expect(job.plan?.model.id == model)
                #expect(job.result?.provenance.engine.id == engine)
                // The job exists on the chosen server, and only there.
                _ = try await chosen.connection.job(job.id, wait: 0)
                let other = await picker.candidates.first { $0.id != engine }!
                await expectEngineError("not_found") { _ = try await other.connection.job(job.id, wait: 0) }
            }

            // A model neither offers: refused, with each server's reason.
            await #expect {
                _ = try await picker.choose(for: generate("gamma"))
            } throws: { error in
                guard case .noEngine(_, let model, let reasons)? = error as? EnginePickerError else { return false }
                return model == "gamma" && reasons.count == 2 && reasons["eng_alpha"]?.contains("gamma") == true
            }
            // An operation neither offers.
            let (choices, refused) = await picker.rank(for: JobRequest(operation: "video.generate"))
            #expect(choices.isEmpty)
            #expect(refused["eng_beta"] == "doesn't offer video.generate")
        }
    }

    @Test("Same model on both: the server with it resident wins; a long queue there sends the job elsewhere")
    func residencyAndQueue() async throws {
        // Slow runs, so jobs pile up on the server they're sent to.
        let slow = MockImageEngine(stepDelay: .milliseconds(150), steps: 20)
        let cold = RenamedMockEngine(inner: slow, renames: ["mock": "shared"], resident: [])
        let warm = RenamedMockEngine(inner: slow, renames: ["mock": "shared"], resident: ["shared"])
        try await withEngines([("eng_cold", cold), ("eng_warm", warm)]) { ports in
            let picker = EnginePicker(candidates: [candidate("eng_cold", ports[0]), candidate("eng_warm", ports[1])],
                                      loadPenalty: 2)

            let first = try await picker.choose(for: generate("shared"))
            #expect(first.candidate.id == "eng_warm")
            #expect(first.resident)
            #expect(first.queueDepth == 0)

            // No model named: the server's default ("shared") decides residency the same way.
            #expect(try await picker.choose(for: generate()).candidate.id == "eng_warm")

            // Three jobs on the warm server (one running, two waiting): 3 ahead > 0 + 2 for loading, so the cold one wins.
            let warmConnection = first.candidate.connection
            var held: [Job] = []
            for _ in 0..<3 { held.append(try await warmConnection.submit(generate("shared"), idempotencyKey: nil)) }
            let next = try await picker.choose(for: generate("shared"))
            #expect(next.candidate.id == "eng_cold")
            #expect(!next.resident)

            // A penalty bigger than the queue keeps it on the resident server.
            await picker.setLoadPenalty(10)
            #expect(try await picker.choose(for: generate("shared")).candidate.id == "eng_warm")

            for job in held { _ = try? await warmConnection.release(job.id) }
        }
    }

    @Test("Pins: prefer falls back when the pinned server can't run the job; only refuses")
    func pinning() async throws {
        let alpha = RenamedMockEngine(inner: MockImageEngine(), renames: ["mock": "alpha"], resident: ["alpha"])
        let beta = RenamedMockEngine(inner: MockImageEngine(), renames: ["mock": "beta"])
        try await withEngines([("eng_alpha", alpha), ("eng_beta", beta)]) { ports in
            let picker = EnginePicker(candidates: [candidate("eng_alpha", ports[0]), candidate("eng_beta", ports[1])])

            // Both serve a request that names no model; alpha is resident, but the pin wins.
            await picker.setPin(.prefer("eng_beta"))
            let (chosen, job) = try await picker.run(generate())
            #expect(chosen.id == "eng_beta")
            #expect(job.plan?.model.id == "beta")
            // Preferred but unable: falls back to the server that offers the model.
            #expect(try await picker.choose(for: generate("alpha")).candidate.id == "eng_alpha")

            await picker.setPin(.only("eng_beta"))
            #expect(try await picker.choose(for: generate("beta")).candidate.id == "eng_beta")
            await #expect(throws: EnginePickerError.pinnedEngineCannotRun(engineID: "eng_beta",
                                                                           reason: "doesn't offer alpha for image.generate")) {
                _ = try await picker.choose(for: generate("alpha"))
            }

            await picker.setPin(.none)
            #expect(try await picker.choose(for: generate()).candidate.id == "eng_alpha")
        }
    }

    @Test("An unreachable server is passed over with a reason; only pairings that are on the network are candidates")
    func unreachableAndAvailability() async throws {
        let alpha = RenamedMockEngine(inner: MockImageEngine(), renames: ["mock": "alpha"])
        try await withEngines([("eng_alpha", alpha)]) { ports in
            let gone = EngineCandidate(id: "eng_gone", name: "Gone",
                                       connection: HTTPEngineConnection(baseURL: URL(string: "http://127.0.0.1:9/mes/v0")!, maxRetries: 0))
            let picker = EnginePicker(candidates: [gone, candidate("eng_alpha", ports[0])])
            let (choices, refused) = await picker.rank(for: generate())
            #expect(choices.map(\.candidate.id) == ["eng_alpha"])
            #expect(refused["eng_gone"]?.hasPrefix("unreachable") == true)
        }

        let pairing = { (id: String) in
            PairedEngine(engineID: id, engineName: id, baseURL: URL(string: "https://192.0.2.1:17610/mes/v0")!,
                         fingerprintSHA256: String(repeating: "0", count: 64), token: "t", clientID: "c")
        }
        let found = DiscoveredEngine(endpoint: .service(name: "Alpha", type: EngineBrowser.serviceType, domain: "local.", interface: nil),
                                     txt: ["id": "eng_alpha", "auth": "paired", "tls": "1"])
        let unpaired = DiscoveredEngine(endpoint: .service(name: "Other", type: EngineBrowser.serviceType, domain: "local.", interface: nil),
                                        txt: ["id": "eng_other"])
        let available = EngineCandidate.available(pairings: [pairing("eng_alpha"), pairing("eng_offline")],
                                                  discovered: [found, unpaired])
        #expect(available.map(\.id) == ["eng_alpha"])
    }

    @Test("Tiers and adapters narrow the offers")
    func tiersAndAdapters() throws {
        let draftOnly = ModelOffer(id: "fast", title: "Fast", license: License.apache2, qualityTiers: [.draft])
        var styled = ModelOffer(id: "styled", title: "Styled", license: License.apache2,
                                qualityTiers: [.standard, .best], namedOnly: true)
        styled.adapters = [AdapterOffer(id: "ink", title: "Ink", strength: .init(min: 0, max: 1, defaultValue: 1),
                                        license: License.apache2)]
        var descriptor = MockImageEngine.descriptor("image.generate")
        descriptor.models = [draftOnly, styled]

        func pick(_ request: JobRequest) -> String? {
            if case .success(let model) = EnginePicker.model(for: request, in: descriptor) { return model }
            return nil
        }
        #expect(pick(generate(quality: "draft")) == "fast")
        // Standard: only the named-only model serves it, so a request that names nothing gets nothing...
        #expect(pick(generate(quality: "standard")) == nil)
        // ...unless it asks for its adapter, which implies it.
        var withAdapter = generate(quality: "standard")
        withAdapter.adapters = [AdapterRequest(id: "ink")]
        #expect(pick(withAdapter) == "styled")
        #expect(pick(generate("fast", quality: "best")) == nil)
    }
}
