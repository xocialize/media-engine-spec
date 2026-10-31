import CoreGraphics
import Foundation
import ImageIO
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
@testable import MockEngineCore
import Testing
import UniformTypeIdentifiers

// R0d exit (engine half): the mock engine passes every conformance test it's eligible for, in open mode and in
// paired mode (with pairing tested), and the suite's bundled schemas are the repo's.

func mockConfig(_ tweak: (inout EngineConfiguration) -> Void = { _ in }) -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-conf-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_conformance", name: "Conformance Mock", implementationName: "mes-mock-engine",
                                implementationVersion: "0.1.0", spoolDirectory: spool)
    c.advertise = false
    c.sweepInterval = .milliseconds(200)
    tweak(&c)
    return c
}

func serve(_ config: EngineConfiguration, engine: any MediaEngine = MockMediaEngine(),
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

func failures(_ report: ConformanceReport) -> String {
    report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" }.joined(separator: "\n")
}

@Suite("Conformance suite against the mock engine", .serialized)
struct MockConformanceTests {
    @Test("Open mode: every applicable BASE, IMAGE and AUDIO test passes")
    func openMode() async throws {
        try await serve(mockConfig()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe)
            #expect(report.failed == 0, "\(failures(report))")
            #expect(report.conformsToBase && report.conformsToImage == true && report.conformsToAudio == true)
            #expect(report.summary == "Base 0.1: conforms, Image 0.1: conforms, Audio 0.1: conforms")
            let skipped = Set(report.results.filter { $0.status == .skip }.map(\.id))
            // IMAGE-010 runs on decompose, whose `output` leaves out JPEG (no alpha, Image §3.2). Asset expiry (BASE-034)
            // waits 60 s; a second pairing (BASE-035) needs paired mode.
            #expect(skipped == ["BASE-005", "BASE-006", "BASE-034", "BASE-035", "BASE-071", "BASE-090"], "skipped: \(skipped.sorted())")
            #expect(report.markdown.contains("✅ conforms"))
            // The mock's bands recompose to the input exactly; it offers composite, so IMAGE-015 skips that refusal.
            let notes = Dictionary(uniqueKeysWithValues: report.results.map { ($0.id, $0.detail ?? "") })
            #expect(notes["IMAGE-016"]?.contains("error of 0.00/255") == true, "\(notes["IMAGE-016"] ?? "")")
            #expect(notes["IMAGE-016"]?.contains("the composite's is 0.00/255") == true, "\(notes["IMAGE-016"] ?? "")")
            #expect(notes["IMAGE-015"]?.contains("composite is offered") == true, "\(notes["IMAGE-015"] ?? "")")
        }
    }

    @Test("decompose without a composite refuses one with 422 unsupported_parameter (IMAGE-015), and still passes IMAGE-014")
    func decomposeWithoutComposite() async throws {
        try await serve(mockConfig(), engine: NoCompositeEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ["IMAGE-014", "IMAGE-015", "IMAGE-016"])
            #expect(report.results.map(\.status) == [.pass, .pass, .pass], "\(failures(report))")
            #expect(report.results.first { $0.id == "IMAGE-015" }?.detail?.contains("composite isn't offered") == true)
        }
    }

    @Test("decompose is asked at draft (IMAGE-003, -014, -016); a slow one fails at the job timeout, is released, and passes with a longer one")
    func slowDecompose() async throws {
        let engine = SlowDecomposeEngine(delay: .seconds(3))
        try await serve(mockConfig(), engine: engine) { port in
            let wire = Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!)
            var options = Probe.Options()
            options.jobTimeout = 1
            let short = await ConformanceRunner.run(try await Probe.connect(wire, options: options), only: ["IMAGE-016"])
            #expect(short.results.first?.status == .fail)
            #expect(short.results.first?.detail?.contains("after 1 s (released") == true, "\(failures(short))")
            options.jobTimeout = 30
            let long = await ConformanceRunner.run(try await Probe.connect(wire, options: options), only: ["IMAGE-003", "IMAGE-014", "IMAGE-016"])
            #expect(long.results.map(\.status) == [.pass, .pass, .pass], "\(failures(long))")
        }
        let qualities = await engine.qualities.all
        #expect(qualities.count >= 5 && qualities.allSatisfy { $0 == .draft }, "decompose ran at \(qualities)")
    }

    @Test("An un-offered output is refused with 422 unsupported_parameter (IMAGE-010) on an engine that narrows output")
    func unofferedOutput() async throws {
        try await serve(mockConfig(), engine: NarrowOutputEngine()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ["IMAGE-010"])
            #expect(report.results.first { $0.id == "IMAGE-010" }?.status == .pass, "\(failures(report))")
        }
    }

    @Test("Output expiry is observed (BASE-071) on an engine with a short TTL")
    func expiry() async throws {
        // Below the schema's 60 s floor (BASE-001 would fail), to observe expiry quickly: run BASE-071 alone.
        try await serve(mockConfig { $0.outputsTTLSeconds = 3 }) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe, only: ["BASE-071"])
            #expect(report.results.map(\.status) == [.pass], "\(report.results.first?.detail ?? "")")
        }
    }

    @Test("Paired mode, pairing as part of the run: auth, TLS identity and pairing tests pass too")
    func pairedMode() async throws {
        let config = mockConfig { $0.mode = .paired; $0.pairingApproval = EngineConfiguration.approveAll }
        try await serve(config) { port in
            let (wire, run) = try await Probe.pair(baseURL: URL(string: "https://localhost:\(port)/mes/v0")!)
            var options = Probe.Options()
            options.pairing = run
            let probe = try await Probe.connect(wire, options: options)
            let report = await ConformanceRunner.run(probe)
            #expect(report.failed == 0, "\(failures(report))")
            let ran = Set(report.results.filter { $0.status == .pass }.map(\.id))
            #expect(ran.isSuperset(of: ["BASE-005", "BASE-006", "BASE-090", "BASE-052", "BASE-080", "BASE-035", "BASE-054"]))
        }
    }

    @Test("Paired mode: a fresh Wire's first request can be the event stream (task-level TLS trust)")
    func pairedFreshEventStream() async throws {
        let config = mockConfig { $0.mode = .paired; $0.pairingApproval = EngineConfiguration.approveAll }
        try await serve(config) { port in
            let baseURL = URL(string: "https://localhost:\(port)/mes/v0")!
            let (wire, run) = try await Probe.pair(baseURL: baseURL)
            let job = JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: ["size": ["width": 16, "height": 16]])
            let id = try await wire.json("POST", "jobs", job).decode(Job.self).id
            let fresh = Wire(baseURL: baseURL, token: run.token, pinned: try #require(wire.presentedFingerprint))
            let (_, frames, _) = try await fresh.frames("jobs/\(id)/events", timeout: 10) { $0.event == "job.output_ready" }
            #expect(frames.last?.event == "job.output_ready")
        }
    }

    @Test("A broken engine fails exactly the rules it breaks: IMAGE-001 (fill repaints kept pixels) and IMAGE-002 (upscale off)")
    func catchesBrokenEngines() async throws {
        let server = MESEngineServer(engine: BrokenEngine(), configuration: mockConfig())
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = try await server.makeApplication { port in continuation.yield(port) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.runService() }
            var it = ports.makeAsyncIterator()
            guard let port = await it.next() else { return }
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe)
            let failed = Set(report.results.filter { $0.status == .fail }.map(\.id))
            #expect(failed == ["IMAGE-001", "IMAGE-002"], "\(failures(report))")
            #expect(report.conformsToBase && report.conformsToImage == false)
            #expect(report.markdown.contains("❌ does not conform"))
            group.cancelAll()
        }
    }

    @Test("The bundled schemas are the repo's")
    func bundledSchemas() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repo.appendingPathComponent("schemas")
        let bundled = Schemas().root.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 13)
        for file in files {
            let relative = file.path.replacingOccurrences(of: source.path + "/", with: "")
            let copy = bundled.appendingPathComponent(relative)
            #expect(try Data(contentsOf: file) == Data(contentsOf: copy), "\(relative) differs; run tools/sync-schemas.sh")
        }
    }
}

/// The mock with two rule violations, to prove the suite catches them: `upscale` returns half the promised size, and
/// `fill` repaints every pixel (black-mask ones included).
struct BrokenEngine: MediaEngine {
    let mock = MockImageEngine()
    func descriptors() async -> [Descriptor] { await mock.descriptors() }
    func residentModels() async -> [String] { await mock.residentModels() }

    func run(_ context: RunContext) async throws -> RunOutput {
        var output = try await mock.run(context)
        guard ["image.upscale", "image.fill"].contains(context.operation) else { return output }
        for (i, produced) in output.outputs.enumerated() {
            guard let file = produced.file, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let shrink = context.operation == "image.upscale"
            let (w, h) = shrink ? (image.width / 2, image.height / 2) : (image.width, image.height)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            if !shrink {
                ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 0.5)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            output.outputs[i].width = w
            output.outputs[i].height = h
        }
        return output
    }
}

@Suite("Client conformance", .serialized)
struct ClientConformanceTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("The mes CLI passes every client test (R0d exit)")
    func mesConforms() async throws {
        let mes = Self.repo.appendingPathComponent(".build/debug/mes").path
        try #require(FileManager.default.isExecutableFile(atPath: mes), "build mes first (swift build --product mes)")
        let report = await ClientSuite.run(client: .mes(mes))
        #expect(report.results.count == 11)
        #expect(report.conforms, "\(report.results.filter { $0.status == .fail }.map { "\($0.id): \($0.detail ?? "")" })")
    }

    @Test("A naive client fails what it gets wrong: busy-polling, never confirming, ignoring Retry-After, exiting 0 on failure")
    func naiveClientFails() async throws {
        // Submits with curl, polls in a tight loop, downloads, never confirms, never retries, always exits 0.
        let naive = """
            url={url}; out={out}
            id=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"operation":"image.generate","inputs":{"prompt":"x"}}' "$url/jobs" | grep -o '"id":"job_[a-z0-9]*"' | head -1 | cut -d'"' -f4)
            for i in $(seq 1 60); do curl -s "$url/jobs/$id" | grep -q '"state":"holding"' && break; sleep 0.05; done
            curl -s -o "$out/out.png" "$url/jobs/$id/outputs/0"
            exit 0
            """
        let report = await ClientSuite.run(client: .command(naive))
        let failed = Set(report.results.filter { $0.status == .fail }.map(\.id))
        #expect(failed.isSuperset(of: ["CLIENT-003", "CLIENT-004", "CLIENT-010", "CLIENT-011", "CLIENT-020", "CLIENT-021", "CLIENT-022"]),
                "failed: \(failed.sorted())")
        #expect(!failed.contains("CLIENT-002") && !failed.contains("CLIENT-005"), "it does submit a valid request and fetch the output")
        #expect(!report.conforms && report.markdown.contains("❌ does not conform"))
    }
}

/// The mock with `image.decompose`'s composite withdrawn: no `composite` output, and `outputs` only `layers`.
struct NoCompositeEngine: MediaEngine {
    let mock = MockImageEngine()

    func descriptors() async -> [Descriptor] {
        await mock.descriptors().map { d in
            guard d.operation == "image.decompose", case .object(var params) = d.params,
                  case .object(var properties)? = params["properties"] else { return d }
            var d = d
            properties["outputs"] = ["type": "array", "minItems": 1, "items": ["enum": ["layers"]]]
            params["properties"] = .object(properties)
            d.params = .object(params)
            d.outputs.removeAll { $0.name == "composite" }
            return d
        }
    }

    func validate(_ request: JobRequest, descriptor: Descriptor) throws { try mock.validate(request, descriptor: descriptor) }
    func run(_ context: RunContext) async throws -> RunOutput { try await mock.run(context) }
}

/// The mock with a slow `image.decompose` that records the tier each decompose ran at.
struct SlowDecomposeEngine: MediaEngine {
    actor Qualities { var all: [QualityTier] = []; func add(_ q: QualityTier) { all.append(q) } }
    let mock = MockImageEngine()
    let delay: Duration
    let qualities = Qualities()

    func descriptors() async -> [Descriptor] { await mock.descriptors() }
    func validate(_ request: JobRequest, descriptor: Descriptor) throws { try mock.validate(request, descriptor: descriptor) }
    func run(_ context: RunContext) async throws -> RunOutput {
        if context.operation == "image.decompose" {
            await qualities.add(context.quality)
            try await Task.sleep(for: delay)
        }
        return try await mock.run(context)
    }
}

@Suite("The mock's decompose")
struct MockDecomposeTests {
    let descriptor = MockImageEngine.descriptor("image.decompose")

    func request(_ plan: String?, count: Int? = nil, outputs: [String]? = nil) -> JobRequest {
        var inputs: [String: RequestInput] = ["image": .one(.inline(mediaType: "image/png", data: Fixtures.png()))]
        if let plan { inputs["prompt"] = .text(plan) }
        var params: [String: JSONValue] = [:]
        if let count { params[ImageProfile.Param.layerCount] = .number(Double(count)) }
        if let outputs { params[ImageProfile.Param.outputs] = .array(outputs.map { .string($0) }) }
        return JobRequest(operation: "image.decompose", inputs: inputs, params: params)
    }

    func refusal(_ request: JobRequest) -> MESError? {
        do { try MockImageEngine().validate(request, descriptor: descriptor); return nil } catch { return error as? MESError }
    }

    @Test("A plan's stated count meets layer_count's rules: a contradiction is 400, above the maximum is 422 (Image §3.2)")
    func statedCount() {
        let plan = "Layer 1: the headline. Layer 2: the badge. Layer 3: the background."
        #expect(MockImageEngine.statedLayerCount(plan) == 3)
        #expect(refusal(request(plan)) == nil)
        #expect(refusal(request(plan, count: 3)) == nil)
        #expect(refusal(request(plan, count: 2))?.code == "invalid_request")
        #expect(refusal(request("Layer 1: text. Layer 9: the background."))?.code == "out_of_limits")
        #expect(refusal(request("a poster")) == nil)
    }

    @Test("outputs without layers is 400 invalid_request (Image §3.2)")
    func outputsNeedLayers() {
        #expect(refusal(request(nil, outputs: ["composite"]))?.code == "invalid_request")
        #expect(refusal(request(nil, outputs: ["layers", "composite"])) == nil)
    }

    @Test("The descriptor narrows layer_count to the mock's maximum and output to formats with alpha")
    func descriptorNarrows() {
        let properties = descriptor.params["properties"]
        #expect(properties?["layer_count"]?["maximum"]?.intValue == MockImageEngine.maxLayers)
        let types = properties?["output"]?["properties"]?["media_type"]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!types.isEmpty && !types.contains("image/jpeg"))
        #expect(descriptor.outputs.first { $0.name == "composite" }?.min == 0)
        #expect(descriptor.outputs.first { $0.name == "layers" }?.max == MockImageEngine.maxLayers)
    }
}

/// The mock with `image.upscale`'s `output` narrowed to 8-bit PNG or JPEG.
struct NarrowOutputEngine: MediaEngine {
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
