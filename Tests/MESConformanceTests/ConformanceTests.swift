import CoreGraphics
import Foundation
import ImageIO
@testable import MESConformance
import MESCore
import MESEngineCore
import MESEngineKit
import MockEngineCore
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

func serve(_ config: EngineConfiguration, _ body: (Int) async throws -> Void) async throws {
    let server = MESEngineServer(engine: MockImageEngine(), configuration: config)
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
    @Test("Open mode: every applicable BASE and IMAGE test passes")
    func openMode() async throws {
        try await serve(mockConfig()) { port in
            let probe = try await Probe.connect(Wire(baseURL: URL(string: "http://127.0.0.1:\(port)/mes/v0")!))
            let report = await ConformanceRunner.run(probe)
            #expect(report.failed == 0, "\(failures(report))")
            #expect(report.conformsToBase && report.conformsToImage == true)
            let skipped = Set(report.results.filter { $0.status == .skip }.map(\.id))
            #expect(skipped == ["BASE-005", "BASE-006", "BASE-071", "BASE-090"], "skipped: \(skipped.sorted())")
            #expect(report.markdown.contains("✅ conforms"))
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
            #expect(ran.isSuperset(of: ["BASE-005", "BASE-006", "BASE-090", "BASE-052", "BASE-080"]))
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
