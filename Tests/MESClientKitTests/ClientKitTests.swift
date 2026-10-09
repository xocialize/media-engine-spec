import Foundation
@testable import MESClientKit
import MESCore
import MESEngineKit
import MESInProcess
@testable import MockEngineCore
import Testing

// MESClientKit against live engines served by MESEngineKit (open and paired modes), and against the same mock
// engine in process. The client code under test is what Lite, Desktop and the `mes` CLI use.

func freshConfig(_ tweak: (inout EngineConfiguration) -> Void = { _ in }) -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-client-test-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_client_test", name: "Client Test", implementationName: "mes-mock-engine",
                                implementationVersion: "0.1.0", spoolDirectory: spool)
    c.sweepInterval = .milliseconds(100)
    c.advertise = false
    tweak(&c)
    return c
}

func withEngine(_ config: EngineConfiguration, engine: MockImageEngine = MockImageEngine(),
                _ body: (Int) async throws -> Void) async throws {
    let server = MESEngineServer(engine: engine, configuration: config)
    let (ports, continuation) = AsyncStream<Int>.makeStream()
    let app = try await server.makeApplication { port in continuation.yield(port) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService() }
        var it = ports.makeAsyncIterator()
        guard let port = await it.next() else { return }
        try await body(port)
        group.cancelAll()
    }
}

func openURL(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)/mes/v0")! }

func tempFile(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
}

func png(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> URL {
    var r = Raster(width: width, height: height)
    for y in 0..<height { for x in 0..<width { r[x, y] = pixel(x, y) } }
    let url = tempFile("png")
    try r.writePNG(to: url)
    return url
}

func mask(width: Int, height: Int, _ value: (Int, Int) -> UInt8) throws -> URL {
    var g = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { g[y * width + x] = value(x, y) } }
    let url = tempFile("png")
    try Raster.writeGreyPNG(g, width: width, height: height, to: url)
    return url
}

actor Recorder<T: Sendable> {
    private(set) var items: [T] = []
    func add(_ item: T) { items.append(item) }
}

func expectEngineError(_ code: String, status: Int? = nil, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected \(code)")
    } catch let error as MESClientError {
        #expect(error.code == code, "\(error)")
        if let status, case .engine(_, let s, _) = error { #expect(s == status) }
    } catch {
        Issue.record("expected \(code), got \(error)")
    }
}

@Suite("MESClientKit over HTTP (open mode)", .serialized)
struct OpenModeClientTests {
    @Test("Fill end to end: inline and uploaded inputs, events, checked downloads, confirm, then 410")
    func fillRoundTrip() async throws {
        try await withEngine(freshConfig()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let info = try await engine.engineInfo()
            #expect(info.id == "eng_client_test" && info.features.contains(.websocket))
            let ops = try await engine.operations()
            #expect(try await engine.operations() == ops, "revalidated with the ETag")
            #expect(ops.operations.contains { $0.operation == "image.fill" })

            let image = try png(width: 24, height: 16) { x, y in (UInt8(x * 10), UInt8(y * 15), 90, 255) }
            let hole = try mask(width: 24, height: 16) { x, _ in x >= 12 ? 255 : 0 }
            let imageInput = try await engine.input(contentsOf: image, inlineLimit: 0)
            let maskInput = try await engine.input(contentsOf: hole, inlineLimit: info.limits.maxInlineBytes)
            guard case .upload = imageInput, case .inline = maskInput else {
                Issue.record("expected an upload (over a 0-byte inline limit) and an inline mask")
                return
            }
            let events = Recorder<Event>()
            let job = try await engine.run(JobRequest(operation: "image.fill", inputs: ["image": .one(imageInput),
                                                                                       "mask": .one(maskInput),
                                                                                       "prompt": .text("sky")],
                                                      params: ["seed": 3])) { await events.add($0) }
            #expect(job.state == .holding && job.outcome == .succeeded)
            let types = await events.items.map(\.type)
            #expect(types.first == .state && types.last == .outputReady && types.contains(.progress))

            let files = try await engine.downloadAll(job, to: FileManager.default.temporaryDirectory
                .appendingPathComponent("mes-dl-\(UUID().uuidString)"))
            #expect(files.count == 1 && files[0].pathExtension == "png")
            let (out, _) = try Raster.load(files[0])
            let (src, _) = try Raster.load(image)
            #expect(out.width == 24 && out[0, 0] == src[0, 0] && out[11, 15] == src[11, 15], "black-mask pixels unchanged")

            let confirmed = try await engine.confirm(job.id)
            #expect(confirmed.state == .purged)
            let output = try #require(job.result?.outputs.first)
            await expectEngineError("gone", status: 410) {
                _ = try await engine.download(job: job.id, output: output, to: tempFile("png"))
            }
        }
    }

    @Test("Errors carry their §12 code; busy carries Retry-After; idempotency keys return the original job")
    func errorsAndIdempotency() async throws {
        let config = freshConfig { $0.maxQueuedJobsPerClient = 1 }
        try await withEngine(config, engine: MockImageEngine(stepDelay: .milliseconds(200), steps: 10)) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port), maxRetries: 0)
            await expectEngineError("unknown_operation", status: 404) {
                _ = try await engine.submit(JobRequest(operation: "image.nope"), idempotencyKey: nil)
            }
            await expectEngineError("unsupported_parameter", status: 422) {
                _ = try await engine.submit(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                       params: ["bogus": 1]), idempotencyKey: nil)
            }
            let request = JobRequest(operation: "image.generate", inputs: ["prompt": .text("slow")])
            let first = try await engine.submit(request, idempotencyKey: "key-1")
            let again = try await engine.submit(request, idempotencyKey: "key-1")
            #expect(again.id == first.id)
            do {
                _ = try await engine.submit(request, idempotencyKey: "key-2")
                Issue.record("expected busy")
            } catch let MESClientError.engine(error, status, retryAfter) {
                #expect(error.code == "busy" && status == 429 && retryAfter == 10)
            }
            #expect(try await engine.release(first.id).outcome == .cancelled)
            await expectEngineError("not_found", status: 404) { _ = try await engine.job("job_missing", wait: 0) }
        }
    }

    @Test("SSE resumes after a given seq; jobs lists the caller's jobs")
    func eventsAfter() async throws {
        try await withEngine(freshConfig()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let job = try await engine.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                      params: ["size": ["width": 16, "height": 16]]))
            var seqs: [Int] = []
            for try await event in engine.events(job: job.id, after: 2) {
                seqs.append(event.seq)
                if event.type == .outputReady { break }
            }
            #expect(seqs.first == 3 && seqs == seqs.sorted())
            #expect(try await engine.jobs(state: .holding).map(\.id) == [job.id])
            _ = try await engine.release(job.id)
        }
    }

    @Test("The WebSocket channel: own jobs' events, pong, error messages")
    func eventChannel() async throws {
        try await withEngine(freshConfig()) { port in
            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let channel = engine.eventChannel()
            defer { channel.close() }
            var messages = channel.messages.makeAsyncIterator()
            try await channel.ping()
            #expect(try await messages.next() == .pong)
            try await channel.subscribeAll()
            guard case .event(let health) = try await messages.next() else { Issue.record("expected health"); return }
            #expect(health.type == .engineHealth)
            let job = try await engine.submit(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")]), idempotencyKey: nil)
            var sawReady = false
            while let message = try await messages.next() {
                if case .event(let e) = message, e.job == job.id, e.type == .outputReady { sawReady = true; break }
            }
            #expect(sawReady)
            try await channel.cancel("job_missing")
            while let message = try await messages.next() {
                if case .error(let e) = message { #expect(e.code == "not_found"); break }
            }
        }
    }

    @Test("A custody-keeping client serves an input through a grant; tokens and revocation are enforced")
    func grants() async throws {
        try await withEngine(freshConfig()) { port in
            let grants = GrantServer(loopbackOnly: true)
            let grantPort = try await grants.start()
            defer { grants.stop() }
            let image = try png(width: 10, height: 8) { x, _ in (UInt8(x * 20), 40, 40, 255) }
            let grant = try grants.grant(image, mediaType: "image/png", host: "127.0.0.1")
            #expect(grant.url.hasPrefix("http://127.0.0.1:\(grantPort)/grants/") && grant.bytes != nil)

            let engine = HTTPEngineConnection(baseURL: openURL(port))
            let job = try await engine.run(JobRequest(operation: "image.upscale", inputs: ["image": .one(.grant(grant))],
                                                      params: ["scale": 2]))
            #expect(job.outcome == .succeeded && job.result?.outputs.first?.width == 20, "\(String(describing: job.error))")

            var wrong = URLRequest(url: URL(string: grant.url)!)
            wrong.setValue("Bearer nope", forHTTPHeaderField: "Authorization")
            #expect((try await URLSession.shared.data(for: wrong).1 as? HTTPURLResponse)?.statusCode == 401)
            grants.revoke(grant)
            var right = URLRequest(url: URL(string: grant.url)!)
            right.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
            #expect((try await URLSession.shared.data(for: right).1 as? HTTPURLResponse)?.statusCode == 404)
            #expect(grants.count == 0)
        }
    }

    @Test("Discovery finds the engine over DNS-SD and resolves it to a working base URL")
    func discovery() async throws {
        let id = "eng_disc_\(UUID().uuidString.prefix(8).lowercased())"
        let config = freshConfig { $0.advertise = true; $0.id = id; $0.name = "MES Test \(id)" }
        try await withEngine(config) { _ in
            var found: DiscoveredEngine?
            for _ in 0..<10 where found == nil {
                found = await EngineBrowser.discover(for: .milliseconds(500)).first { $0.engineID == id }
            }
            let engine = try #require(found)
            #expect(engine.auth == .open && engine.tls == false && engine.path == "/mes/v0" && engine.profiles == ["image/0.1"])
            let url = try await engine.resolve()
            #expect(try await HTTPEngineConnection(baseURL: url).engineInfo().id == id)
        }
    }
}

@Suite("MESClientKit pairing (paired mode)", .serialized)
struct PairingClientTests {
    @Test("Pair: both sides show the same code; the pinned connection works; a wrong pin and unpairing don't")
    func pairAndUse() async throws {
        let prompts = Recorder<PairingPrompt>()
        let config = freshConfig {
            $0.mode = .paired
            $0.pairingApproval = { prompt in await prompts.add(prompt); return true }
        }
        try await withEngine(config) { port in
            let url = URL(string: "https://localhost:\(port)/mes/v0")!
            let me = ClientIdentity.generate(name: "Test Mac")

            let unpinned = HTTPEngineConnection(baseURL: url)
            do { _ = try await unpinned.engineInfo(); Issue.record("an unpinned TLS connection must fail") } catch {}

            let pairing = try await Pairing.begin(baseURL: url, identity: me)
            #expect(pairing.code.count == 6 && pairing.engine.auth == .paired)
            guard case .approved(let paired) = try await pairing.confirm(wait: 10) else {
                Issue.record("expected approval"); return
            }
            #expect(await prompts.items.first?.code == pairing.code, "the operator saw the same code")
            #expect(paired.clientID == me.id && paired.fingerprintSHA256 == pairing.engine.tls?.fingerprintSHA256)
            let decoded = try MESJSON.decoder.decode(PairedEngine.self, from: try MESJSON.encoder.encode(paired))
            #expect(decoded == paired)

            let engine = HTTPEngineConnection(paired: paired)
            #expect(try await engine.operations().operations.count == 13)
            let job = try await engine.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                      params: ["size": ["width": 16, "height": 16]]))
            #expect(job.outcome == .succeeded)
            let files = try await engine.downloadAll(job, to: FileManager.default.temporaryDirectory
                .appendingPathComponent("mes-dl-\(UUID().uuidString)"))
            #expect(files.count == 1)

            let channel = engine.eventChannel()
            var messages = channel.messages.makeAsyncIterator()
            try await channel.ping()
            #expect(try await messages.next() == .pong, "wss with the pin and token")
            channel.close()

            let wrongPin = HTTPEngineConnection(baseURL: url, token: paired.token, pinnedFingerprint: Data(repeating: 1, count: 32))
            do { _ = try await wrongPin.engineInfo(); Issue.record("a wrong pin must fail") } catch {}

            try await Pairing.unpair(paired)
            await expectEngineError("unauthorized", status: 401) { _ = try await engine.operations() }
        }
    }

    @Test("A declined pairing throws pairing_rejected")
    func declined() async throws {
        let config = freshConfig { $0.mode = .paired; $0.pairingApproval = { _ in false } }
        try await withEngine(config) { port in
            let pairing = try await Pairing.begin(baseURL: URL(string: "https://localhost:\(port)/mes/v0")!,
                                                  identity: .generate(name: "Mallory"))
            await expectEngineError("pairing_rejected", status: 403) { _ = try await pairing.confirm(wait: 5) }
        }
    }
}

@Suite("MESInProcess: the same client API without a network", .serialized)
struct InProcessTests {
    @Test("Generate, events, download, confirm and errors, as over HTTP")
    func inProcess() async throws {
        let engine = try await InProcessEngine.start(engine: MockImageEngine(), configuration: freshConfig())
        let info = try await engine.engineInfo()
        #expect(info.id == "eng_client_test")
        #expect(try await engine.operations().operations.count == 13)
        let events = Recorder<EventType>()
        let job = try await engine.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                  params: ["size": ["width": 32, "height": 16]])) { await events.add($0.type) }
        #expect(job.outcome == .succeeded && job.result?.provenance.engine.id == "eng_client_test")
        #expect(await events.items.last == .outputReady)
        let files = try await engine.downloadAll(job, to: FileManager.default.temporaryDirectory
            .appendingPathComponent("mes-ip-\(UUID().uuidString)"))
        #expect(try Raster.load(files[0]).0.width == 32)
        #expect(try await engine.confirm(job.id).state == .purged)

        let image = try png(width: 8, height: 8) { _, _ in (10, 20, 30, 255) }
        let upload = try await engine.upload(contentsOf: image, mediaType: "image/png")
        let upscaled = try await engine.run(JobRequest(operation: "image.upscale", inputs: ["image": .one(.upload(upload.uploadID))],
                                                       params: ["scale": 2]))
        #expect(upscaled.result?.outputs.first?.width == 16)
        await expectEngineError("unknown_operation", status: 404) {
            _ = try await engine.submit(JobRequest(operation: "image.nope"), idempotencyKey: nil)
        }
        await engine.stop()
    }
}
