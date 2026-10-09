import ArgumentParser
import Foundation
import MESClientKit
import MESConformance
import MESCore

@main
struct ConformanceCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mes-conformance",
        abstract: "The MES conformance suite: tests an engine against Base 0.1 and the profiles it offers.",
        version: Catalogue.version,
        subcommands: [EngineCommand.self, ListCommand.self])
}

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Run the BASE and IMAGE tests against an engine, and write a JSON and Markdown report.",
        discussion: """
            Open-mode engines need only their URL. For a paired engine, either pair as part of the run (--pair, which \
            also tests pairing; the engine's operator approves), reuse a `mes pair` (--paired-state), or pass --token \
            and --pin. Exits 0 when the engine conforms.
            """)

    @Argument(help: "The engine's base URL, e.g. http://127.0.0.1:17600/mes/v0") var url: String
    @Option(help: "A bearer token from pairing.") var token: String?
    @Option(help: "The engine certificate's SHA-256 (hex), pinned.") var pin: String?
    @Option(help: "A `mes` state directory with a pairing for this engine.") var pairedState: String?
    @Flag(help: "Pair as part of the run (tests pairing; the engine's operator approves). Unpairs at the end.") var pair = false
    @Option(help: "Observe output expiry (BASE-071) when the engine's outputs TTL is at most this many seconds.") var maxTTLWait = 30
    @Option(help: "This machine's address as a LAN engine sees it, for the grants test.") var grantHost: String?
    @Option(help: "Only these tests, comma-separated (e.g. BASE-020,IMAGE-001).") var only: String?
    @Option(name: .shortAndLong, help: "Directory for report.json and report.md.") var out = "mes-conformance-report"

    func run() async throws {
        guard let base = URL(string: url), base.scheme == "http" || base.scheme == "https" else {
            throw ValidationError("\(url) isn't an http(s) URL.")
        }
        var options = Probe.Options()
        options.maxTTLWait = maxTTLWait
        options.grantHost = grantHost
        var wire = Wire(baseURL: base, token: token, pinned: pin.flatMap(Self.data(hex:)))

        if let pairedState {
            let file = URL(fileURLWithPath: (pairedState as NSString).expandingTildeInPath).appendingPathComponent("engines.json")
            let engines = (try? MESJSON.decoder.decode([PairedEngine].self, from: Data(contentsOf: file))) ?? []
            guard let paired = engines.first(where: { $0.baseURL == base }) ?? (engines.count == 1 ? engines.first : nil) else {
                throw ValidationError("No pairing for \(url) in \(file.path).")
            }
            wire = Wire(baseURL: base, token: paired.token, pinned: Self.data(hex: paired.fingerprintSHA256))
        } else if pair {
            let (paired, run) = try await Probe.pair(baseURL: base) { code in
                print("Pairing as \"mes-conformance\". Check the engine shows \(code), and approve it there.")
            }
            wire = paired
            options.pairing = run
        }

        let probe = try await Probe.connect(wire, options: options)
        print("\(probe.info.name) (\(probe.info.id)) · \(probe.info.implementation.name) \(probe.info.implementation.version) · \(probe.info.auth.rawValue)")
        let ids = only.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let report = await ConformanceRunner.run(probe, only: ids) { r in
            let mark = switch r.status { case .pass: "✅"; case .fail: "❌"; case .skip: "➖" }
            print("\(mark) \(r.id)  \(r.title)\(r.detail.map { "\n     \($0)" } ?? "")")
        }
        let directory = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"))
        try report.markdown.write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print("\n\(report.passed) passed · \(report.failed) failed · \(report.skipped) skipped — Base 0.1: \(report.conformsToBase ? "conforms" : "does not conform")"
            + (report.conformsToImage.map { ", Image 0.1: \($0 ? "conforms" : "does not conform")" } ?? ""))
        print("Report: \(directory.path)/report.md")
        if report.failed > 0 { throw ExitCode.failure }
    }

    static func data(hex: String) -> Data? {
        var bytes = [UInt8]()
        var it = hex.lowercased().makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes.count == 32 ? Data(bytes) : nil
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Print the test catalogue as Markdown.")
    func run() { print(Catalogue.markdown, terminator: "") }
}
