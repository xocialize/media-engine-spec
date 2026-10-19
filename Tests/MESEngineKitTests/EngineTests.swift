import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import NIOCore
import Testing

// Integration tests: the mock engine served by MESEngineKit on a live loopback port, driven over HTTP, with every
// response checked against the schemas in schemas/v0 (the same files tools/validate.py checks).

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let schemaRoot = repo.appendingPathComponent("schemas/v0")
let loader = SchemaLoader()

func conforms(_ body: ByteBuffer, to target: String) -> [SchemaValidator.Issue] {
    let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
    let url = schemaRoot.appendingPathComponent(parts[0])
    guard let document = loader.load(url),
          let value = try? MESJSON.decoder.decode(JSONValue.self, from: Data(body.readableBytesView)) else {
        return [.init(path: "$", message: "unparseable body or schema")]
    }
    var node = document
    if parts.count > 1 { for k in parts[1].split(separator: "/") { node = node[String(k)] ?? .null } }
    return SchemaValidator(loader: loader).validate(value, against: node, in: document, base: url)
}

func decode<T: Decodable>(_ type: T.Type, _ body: ByteBuffer) throws -> T {
    try MESJSON.decoder.decode(T.self, from: Data(body.readableBytesView))
}

func jsonBody<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(bytes: try MESJSON.encoder.encode(value)) }

func freshConfig(_ tweak: (inout EngineConfiguration) -> Void = { _ in }) -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-test-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_test", name: "Test", implementationName: "mes-mock-engine",
                                implementationVersion: "0.1.0", spoolDirectory: spool)
    c.sweepInterval = .milliseconds(100)
    c.advertise = false
    tweak(&c)
    return c
}

func spoolFiles(_ c: EngineConfiguration) -> [String] {
    let e = FileManager.default.enumerator(at: c.spoolDirectory, includingPropertiesForKeys: [.isRegularFileKey])
    return (e?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .map(\.lastPathComponent)
}

func pngData(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
    var r = Raster(width: width, height: height)
    for y in 0..<height { for x in 0..<width { r[x, y] = pixel(x, y) } }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try r.writePNG(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try Data(contentsOf: url)
}

func greyPNG(width: Int, height: Int, _ value: (Int, Int) -> UInt8) throws -> Data {
    var g = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { g[y * width + x] = value(x, y) } }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try Raster.writeGreyPNG(g, width: width, height: height, to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try Data(contentsOf: url)
}

func raster(_ data: Data) throws -> Raster {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try Raster.load(url).0
}

let base = "/mes/v0"

extension TestClientProtocol {
    func post<T: Encodable>(_ path: String, _ value: T, headers: HTTPFields = [:]) async throws -> TestResponse {
        var h = headers
        h[.contentType] = "application/json"
        return try await execute(uri: base + path, method: .post, headers: h, body: try jsonBody(value))
    }

    func get(_ path: String, headers: HTTPFields = [:]) async throws -> TestResponse {
        try await execute(uri: base + path, method: .get, headers: headers)
    }

    func upload(_ data: Data, mediaType: String = "image/png") async throws -> Upload {
        let r = try await execute(uri: base + "/uploads", method: .post, headers: [.contentType: mediaType],
                                  body: ByteBuffer(bytes: data))
        #expect(r.status == .created)
        #expect(conforms(r.body, to: "base/upload.schema.json").isEmpty)
        return try decode(Upload.self, r.body)
    }

    /// Submits and long-polls until the job leaves the active states.
    func run(_ request: JobRequest) async throws -> Job {
        let r = try await post("/jobs", request)
        #expect(r.status == .created, "\(String(buffer: r.body))")
        var job = try decode(Job.self, r.body)
        for _ in 0..<20 where [.received, .fetching, .waiting, .running].contains(job.state) {
            job = try decode(Job.self, try await get("/jobs/\(job.id)?wait=5").body)
        }
        return job
    }

    func errorCode(_ r: TestResponse) throws -> String { try decode(ErrorBody.self, r.body).error.code }
}

@Suite("MESEngineKit + mock engine: Base 0.1 and Image 0.1 over HTTP")
struct EngineTests {
    func app(_ config: EngineConfiguration, engine: MockImageEngine = MockImageEngine()) async throws -> some ApplicationProtocol {
        try await MESEngineServer(engine: engine, configuration: config).makeApplication()
    }

    @Test("Engine info, operations, descriptors and health validate against their schemas; ETag works")
    func discovery() async throws {
        try await app(freshConfig()).test(.live) { client in
            let info = try await client.get("/engine")
            #expect(info.status == .ok && info.headers[.mesVersion] == "0.1" && info.headers[.mesRequestID] != nil)
            #expect(conforms(info.body, to: "base/engine-info.schema.json").isEmpty)
            let ops = try await client.get("/operations")
            #expect(conforms(ops.body, to: "base/operations-list.schema.json").isEmpty)
            let list = try decode(OperationsList.self, ops.body)
            #expect(list.operations.count == 14)
            let etag = try #require(ops.headers[.eTag])
            #expect(try await client.get("/operations", headers: [.ifNoneMatch: etag]).status == .notModified)
            let fill = try await client.get("/operations/image.fill")
            #expect(conforms(fill.body, to: "base/descriptor.schema.json").isEmpty)
            #expect(try client.errorCode(try await client.get("/operations/image.nope")) == "unknown_operation")
            #expect(conforms(try await client.get("/health").body, to: "base/health.schema.json").isEmpty)
        }
    }

    @Test("Generate: holding with a snapped size and seed; events, ranged output, confirm, 410; nothing left in the spool")
    func lifecycle() async throws {
        let config = freshConfig()
        try await app(config).test(.live) { client in
            let job = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a lighthouse")],
                                                      params: ["size": ["width": 100, "height": 75], "seed": 42],
                                                      policy: Policy(license: .commercialUse), clientRef: "t1"))
            #expect(job.state == .holding && job.outcome == .succeeded)
            #expect(job.warnings.contains { $0.code == "size_snapped" })
            let out = try #require(job.result?.outputs.first)
            #expect(out.width == 96 && out.height == 80 && job.result?.effective["seed"] == 42)
            #expect(job.result?.provenance.model.license.commercialUse == .yes)
            let snap = try await client.get("/jobs/\(job.id)")
            #expect(conforms(snap.body, to: "base/job.schema.json").isEmpty, "\(conforms(snap.body, to: "base/job.schema.json"))")

            let ranged = try await client.get("/jobs/\(job.id)/outputs/0", headers: [.range: "bytes=0-7"])
            #expect(ranged.status == .partialContent && ranged.body.readableBytes == 8)
            #expect(ranged.headers[.eTag] == "\"sha256:\(out.sha256)\"")
            let full = try await client.get("/jobs/\(job.id)/outputs/0")
            #expect(Hashing.sha256(Data(full.body.readableBytesView)) == out.sha256)

            let confirmed = try await client.post("/jobs/\(job.id)/confirm", [String: String]())
            #expect(try decode(Job.self, confirmed.body).state == .purged)
            #expect(try await client.get("/jobs/\(job.id)/outputs/0").status == .gone)
            #expect(try client.errorCode(try await client.post("/jobs/\(job.id)/confirm", [String: String]())) == "already_confirmed")
            #expect(spoolFiles(config).isEmpty, "\(spoolFiles(config))")

            // The SSE stream replays everything and ends after job.ended.
            let sse = String(buffer: try await client.get("/jobs/\(job.id)/events").body)
            let frames = sse.components(separatedBy: "\n\n").filter { $0.contains("data: ") }
            #expect(frames.first?.contains("event: job.state") == true && frames.last?.contains("event: job.ended") == true)
            for frame in frames {
                let data = frame.components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!.dropFirst(6)
                #expect(conforms(ByteBuffer(string: String(data)), to: "base/event.schema.json").isEmpty, "\(frame)")
            }
            let resumed = String(buffer: try await client.get("/jobs/\(job.id)/events", headers: [.lastEventID: "\(frames.count - 1)"]).body)
            #expect(resumed.components(separatedBy: "\n\n").filter { $0.contains("data: ") }.count == 1)
        }
    }

    @Test("IMAGE-001: fill keeps black-mask pixels byte-identical; uploads are single-use; inputs leave the spool")
    func fillPreservesUnmasked() async throws {
        let config = freshConfig()
        try await app(config).test(.live) { client in
            let image = try await client.upload(try pngData(width: 64, height: 48) { x, y in (UInt8(x * 4), UInt8(y * 5), 120, 255) })
            let mask = try await client.upload(try greyPNG(width: 64, height: 48) { x, _ in x < 32 ? 0 : 255 })
            let job = try await client.run(JobRequest(operation: "image.fill",
                                                      inputs: ["image": .one(.upload(image.uploadID)), "mask": .one(.upload(mask.uploadID)),
                                                               "prompt": .text("a red umbrella")]))
            #expect(job.state == .holding)
            #expect(!spoolFiles(config).contains { $0.hasPrefix("image-") || $0.hasPrefix("mask-") }, "inputs deleted after the run")
            let before = try raster(try pngData(width: 64, height: 48) { x, y in (UInt8(x * 4), UInt8(y * 5), 120, 255) })
            let after = try raster(Data(try await client.get("/jobs/\(job.id)/outputs/0").body.readableBytesView))
            var unchanged = true, changed = false
            for y in 0..<48 {
                for x in 0..<64 {
                    if x < 32, after[x, y] != before[x, y] { unchanged = false }
                    if x >= 32, after[x, y] != before[x, y] { changed = true }
                }
            }
            #expect(unchanged && changed)
            let reuse = try await client.post("/jobs", JobRequest(operation: "image.fill",
                                                                  inputs: ["image": .one(.upload(image.uploadID)), "mask": .one(.upload(mask.uploadID))]))
            #expect(reuse.status.code == 422)
            #expect(try client.errorCode(reuse) == "input_invalid")
        }
    }

    @Test("IMAGE-002/003/004: upscale is exactly ×scale; restore keeps size; matte gives a grey mask and an RGBA cut-out")
    func imageRules() async throws {
        try await app(freshConfig()).test(.live) { client in
            let png = try pngData(width: 30, height: 20) { x, y in x > 10 && x < 20 && y > 5 && y < 15 ? (250, 40, 40, 255) : (20, 20, 20, 255) }
            let up = try await client.run(JobRequest(operation: "image.upscale",
                                                     inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                                                     params: ["scale": 4]))
            #expect(up.result?.outputs.first?.width == 120 && up.result?.outputs.first?.height == 80)
            let restore = try await client.run(JobRequest(operation: "image.restore",
                                                          inputs: ["image": .one(.inline(mediaType: "image/png", data: png))]))
            #expect(restore.result?.outputs.first?.width == 30)
            let matte = try await client.run(JobRequest(operation: "image.matte",
                                                        inputs: ["image": .one(.inline(mediaType: "image/png", data: png))]))
            #expect(Set(matte.result?.outputs.map(\.name) ?? []) == ["mask", "extract"])
            #expect(matte.result?.outputs.first { $0.name == "mask" }?.kind == .mask)
        }
    }

    @Test("Data in and out: segment takes points; describe returns a value that fits the vocabulary")
    func dataInputsAndOutputs() async throws {
        try await app(freshConfig()).test(.live) { client in
            let png = try pngData(width: 40, height: 40) { _, _ in (90, 90, 90, 255) }
            let seg = try await client.run(JobRequest(operation: "image.segment",
                                                      inputs: ["image": .one(.inline(mediaType: "image/png", data: png)),
                                                               "points": .one(.data([["x": 0.5, "y": 0.5, "label": "include"]]))],
                                                      params: ["count": 2]))
            #expect(seg.result?.outputs.filter { $0.name == "masks" }.count == 2)
            let noPrompt = try await client.post("/jobs", JobRequest(operation: "image.segment",
                                                                     inputs: ["image": .one(.inline(mediaType: "image/png", data: png))]))
            #expect(noPrompt.status == .badRequest)
            let describe = try await client.run(JobRequest(operation: "image.describe",
                                                           inputs: ["image": .one(.inline(mediaType: "image/png", data: png))]))
            let value = try #require(describe.result?.outputs.first?.value)
            let vocab = schemaRoot.appendingPathComponent("profiles/image/vocabulary.schema.json")
            let doc = try #require(loader.load(vocab))
            #expect(SchemaValidator(loader: loader).validate(value, against: doc["$defs"]!["description"]!, in: doc, base: vocab).isEmpty)
        }
    }

    @Test("Policy and validation: policy_unmet, unknown and out-of-range params, size+aspect, versions, origins")
    func refusals() async throws {
        try await app(freshConfig()).test(.live) { client in
            let research = try await client.post("/jobs", JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                                     model: "mock-research", policy: Policy(license: .commercialUse)))
            #expect(research.status.code == 422)
            #expect(try client.errorCode(research) == "policy_unmet")
            #expect(conforms(research.body, to: "base/error.schema.json").isEmpty)
            let anyPolicy = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                            params: ["quality": "best", "size": ["width": 32, "height": 32]],
                                                            model: "mock-research"))
            #expect(anyPolicy.result?.provenance.model.license.commercialUse == .no, "named research model runs under policy any")
            let unknown = try await client.post("/jobs", JobRequest(operation: "image.fill", inputs: ["prompt": .text("x")],
                                                                    params: ["guidance": 3]))
            #expect(unknown.status.code == 422 || unknown.status.code == 400)
            let png = try pngData(width: 8, height: 8) { _, _ in (1, 2, 3, 255) }
            let guidance = try await client.post("/jobs", JobRequest(operation: "image.upscale",
                                                                     inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                                                                     params: ["guidance": 3]))
            #expect(try client.errorCode(guidance) == "unsupported_parameter")
            let range = try await client.post("/jobs", JobRequest(operation: "image.relight",
                                                                  inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                                                                  params: ["strength": 2]))
            #expect(try client.errorCode(range) == "out_of_limits")
            let both = try await client.post("/jobs", JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                                 params: ["size": ["width": 64, "height": 64], "aspect": "1:1"]))
            #expect(both.status == .badRequest)
            #expect(try client.errorCode(try await client.post("/jobs", JobRequest(operation: "image.nope"))) == "unknown_operation")
            let v = try await client.get("/engine", headers: [.mesVersion: "9.9"])
            #expect(v.status == .badRequest)
            #expect(try decode(ErrorBody.self, v.body).error.supportedVersions == ["0.1"])
            let o = try await client.get("/engine", headers: [.origin: "https://evil.example"])
            #expect(o.status == .forbidden)
            #expect(try client.errorCode(o) == "origin_not_allowed")
        }
    }

    @Test("A named-only model (research) never runs by default, at any tier; named, it runs")
    func namedOnly() async throws {
        try await app(freshConfig()).test(.live) { client in
            let generate = try decode(Descriptor.self, try await client.get("/operations/image.generate").body)
            #expect(generate.models.first { $0.id == "mock-research" }?.namedOnly == true)
            let best = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                       params: ["quality": "best", "size": ["width": 16, "height": 16]]))
            #expect(best.plan?.model.id == "mock", "an unnamed best-tier request takes the default, not the research model")
            let named = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                        params: ["size": ["width": 16, "height": 16]], model: "mock-research"))
            #expect(named.plan?.model.id == "mock-research" && named.plan?.model.license.commercialUse == .no)
        }
    }

    @Test("An engine may refine the default per request; an answer outside the allowed candidates is ignored")
    func refinedDefault() async throws {
        let server = MESEngineServer(engine: RefiningEngine(), configuration: freshConfig())
        try await server.makeApplication().test(.live) { client in
            func run(_ prompt: String, policy: Policy? = nil) async throws -> Job {
                try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompt)],
                                                params: ["size": ["width": 16, "height": 16]], policy: policy))
            }
            let plain = try await run("plain"), alt = try await run("use alt"), research = try await run("use research")
            let commercial = try await run("use alt", policy: Policy(license: .commercialUse))
            #expect(plain.plan?.model.id == "mock")
            #expect(alt.plan?.model.id == "mock-alt" && alt.result?.provenance.model.id == "mock-alt")
            #expect(research.plan?.model.id == "mock", "named-only is never a default")
            #expect(commercial.plan?.model.id == "mock", "the refined choice must satisfy the policy")
        }
    }

    @Test("An output the descriptor doesn't offer is 422 unsupported_parameter, not out_of_limits (Image §1.2)")
    func unofferedOutput() async throws {
        let server = MESEngineServer(engine: EightBitEngine(), configuration: freshConfig())
        try await server.makeApplication().test(.live) { client in
            let png = try pngData(width: 8, height: 8) { _, _ in (1, 2, 3, 255) }
            func upscale(_ output: JSONValue) async throws -> String? {
                try client.errorCode(try await client.post("/jobs", JobRequest(
                    operation: "image.upscale", inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                    params: ["scale": 2, "output": output])))
            }
            #expect(try await upscale(["bit_depth": 16]) == "unsupported_parameter")
            #expect(try await upscale(["media_type": "image/tiff"]) == "unsupported_parameter")
            let fine = try await client.post("/jobs", JobRequest(
                operation: "image.upscale", inputs: ["image": .one(.inline(mediaType: "image/png", data: png))],
                params: ["scale": 2, "output": ["media_type": "image/png", "bit_depth": 8]]))
            #expect(fine.status.code < 300)
        }
    }

    @Test("Release cancels a running job, frees the slot and cleans the spool")
    func cancellation() async throws {
        let config = freshConfig()
        try await app(config, engine: MockImageEngine(stepDelay: .milliseconds(150), steps: 20)).test(.live) { client in
            let png = try pngData(width: 8, height: 8) { _, _ in (9, 9, 9, 255) }
            let slow = try decode(Job.self, try await client.post("/jobs", JobRequest(operation: "image.restore",
                inputs: ["image": .one(.inline(mediaType: "image/png", data: png))])).body)
            let queued = try decode(Job.self, try await client.post("/jobs", JobRequest(operation: "image.score",
                inputs: ["image": .one(.inline(mediaType: "image/png", data: png))])).body)
            try await Task.sleep(for: .milliseconds(400))
            let released = try decode(Job.self, try await client.execute(uri: base + "/jobs/\(slow.id)", method: .delete).body)
            #expect(released.state == .purged && released.outcome == .cancelled)
            var next = queued
            for _ in 0..<20 where next.state != .holding { next = try decode(Job.self, try await client.get("/jobs/\(queued.id)?wait=5").body) }
            #expect(next.state == .holding, "the slot passed to the next job")
            try await Task.sleep(for: .milliseconds(300))
            #expect(!spoolFiles(config).contains { $0.hasPrefix("image-") })
        }
    }

    @Test("Outputs expire after their TTL: outcome expired, 410")
    func expiry() async throws {
        try await app(freshConfig { $0.outputsTTLSeconds = 1 }).test(.live) { client in
            let job = try await client.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                      params: ["size": ["width": 16, "height": 16]]))
            try await Task.sleep(for: .milliseconds(1600))
            let after = try decode(Job.self, try await client.get("/jobs/\(job.id)").body)
            #expect(after.state == .purged && after.outcome == .expired)
            #expect(try await client.get("/jobs/\(job.id)/outputs/0").status == .gone)
        }
    }

    @Test("Base §13 rule 3: a start wipes media an interrupted run left in the spool")
    func crashSweep() async throws {
        let config = freshConfig()
        let leftover = config.spoolDirectory.appendingPathComponent("jobs/job_crashed/inputs")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: leftover.appendingPathComponent("image-0.png"))
        let uploads = config.spoolDirectory.appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: uploads.appendingPathComponent("upl_old"))
        _ = try await app(config)
        #expect(spoolFiles(config).isEmpty)
    }

    @Test("Grants: pulled from the submitting host with the token; a wrong token or checksum fails the job")
    func grants() async throws {
        let png = try pngData(width: 12, height: 12) { x, _ in (UInt8(x * 20), 0, 0, 255) }
        let grantRouter = Router()
        grantRouter.get("g/:name") { request, _ -> Response in
            guard request.headers[.authorization] == "Bearer good-token-0123456789" else { return Response(status: .unauthorized) }
            return Response(status: .ok, headers: [.contentType: "image/png"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: png)))
        }
        let grantApp = Application(router: grantRouter, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        try await grantApp.test(.live) { grantClient in
            let grantPort = try #require(grantClient.port)
            try await app(freshConfig()).test(.live) { client in
                func grant(_ token: String, sha: String?) -> RequestInput {
                    .one(.grant(Grant(url: "http://localhost:\(grantPort)/g/img", token: token, mediaType: "image/png", sha256: sha)))
                }
                let ok = try await client.run(JobRequest(operation: "image.restore",
                                                         inputs: ["image": grant("good-token-0123456789", sha: Hashing.sha256(png))]))
                #expect(ok.state == .holding, "\(String(describing: ok.error))")
                let refused = try await client.run(JobRequest(operation: "image.restore", inputs: ["image": grant("bad-token-0123456789", sha: nil)]))
                #expect(refused.outcome == .failed && refused.error?.code == "input_fetch_failed")
                let tampered = try await client.run(JobRequest(operation: "image.restore",
                                                               inputs: ["image": grant("good-token-0123456789", sha: String(repeating: "0", count: 64))]))
                #expect(tampered.outcome == .failed && tampered.error?.code == "input_fetch_failed")
                #expect(GrantFetcher.hostAllowed("evil.example", clientHost: "127.0.0.1") == false)
                #expect(GrantFetcher.hostAllowed("192.168.0.9", clientHost: "192.168.0.9"))
                #expect(GrantFetcher.hostAllowed("192.168.0.10", clientHost: "192.168.0.9") == false)
            }
        }
    }
}

/// The mock with a second generate model, preferred when the prompt asks for it (Base §6 rule 2: a default may depend
/// on the request). "mock-alt" is research-licensed, so a commercial-use policy rules it out.
struct RefiningEngine: MediaEngine {
    let mock = MockImageEngine()

    func descriptors() async -> [Descriptor] {
        await mock.descriptors().map { d in
            guard d.operation == "image.generate" else { return d }
            var d = d
            d.models.append(ModelOffer(id: "mock-alt", title: "Mock alternative",
                                       license: License(spdx: "LicenseRef-Research", commercialUse: .no),
                                       memoryClass: .small, speedClass: .fast, qualityTiers: [.standard]))
            return d
        }
    }

    func run(_ context: RunContext) async throws -> RunOutput { try await mock.run(context) }

    func defaultModel(for request: JobRequest, descriptor: Descriptor, kitChoice: ModelOffer, candidates: [ModelOffer]) -> ModelOffer? {
        guard case .text(let prompt)? = request.inputs?["prompt"] else { return nil }
        if prompt.contains("alt") { return candidates.first { $0.id == "mock-alt" } }
        if prompt.contains("research") { return descriptor.models.first { $0.id == "mock-research" } }
        return nil
    }
}

/// The mock with `image.upscale`'s `output` narrowed to 8-bit PNG or JPEG, as an engine whose models run at 8 bits.
struct EightBitEngine: MediaEngine {
    let mock = MockImageEngine()

    func descriptors() async -> [Descriptor] {
        await mock.descriptors().map { d in
            guard d.operation == "image.upscale", case .object(var params) = d.params,
                  case .object(var properties)? = params["properties"] else { return d }
            var d = d
            properties["output"] = ["type": "object", "additionalProperties": false,
                                    "properties": ["media_type": ["enum": ["image/png", "image/jpeg"]], "bit_depth": ["enum": [8]]]]
            params["properties"] = .object(properties)
            d.params = .object(params)
            return d
        }
    }

    func run(_ context: RunContext) async throws -> RunOutput { try await mock.run(context) }
}
