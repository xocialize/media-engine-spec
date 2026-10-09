import ArgumentParser
import Foundation
import MESClientKit
import MESCore

@main
struct MES: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mes",
        abstract: "A command-line client for Media Engine Specification (MES) engines.",
        discussion: """
            Engines are found over DNS-SD, or named by URL. Open-mode engines (loopback) need nothing more; paired \
            engines need `mes pair` once.

              mes discover
              mes ops
              mes run image.generate --input prompt="a lighthouse at dusk" --param size=1024x768
              mes run image.fill --input image=photo.png --input mask=mask.png --input prompt="clear sky"
            """,
        version: MESClientKit.baseVersion,
        subcommands: [Discover.self, Pair.self, Unpair.self, Engines.self, Info.self, Ops.self, Describe.self, Run.self,
                      Jobs.self, Get.self, Download.self, Confirm.self, Release.self])

    /// Line-buffers standard output, so results and the progress notes on standard error stay in order when piped.
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand { try await async.run() } else { try command.run() }
        } catch {
            exit(withError: error)
        }
    }
}

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List engines advertised over DNS-SD (_mes-engine._tcp).")
    @Option(help: "Seconds to browse.") var seconds = 2

    func run() async throws {
        let engines = await EngineBrowser.discover(for: .seconds(seconds))
        if engines.isEmpty { note("No engines found."); return }
        for engine in engines {
            let url = (try? await engine.resolve()).map(\.absoluteString) ?? "unresolved"
            print("\(engine.serviceName)\n  id: \(engine.id) · \(engine.auth?.rawValue ?? "?")\(engine.tls ? " · tls" : "")"
                + " · \(engine.profiles.joined(separator: ", ")) · \(engine.version ?? "")\n  \(url)")
        }
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pair with an engine: compare the code on both screens, then wait for the engine's operator.")
    @Argument(help: "The engine's base URL (https://host:port/mes/v0), or a discovered engine's id or name.") var engine: String
    @Option(help: "How this client is named on the engine's screen.") var name: String?
    @Option(help: "Seconds to wait for approval.") var timeout = 300
    @Option(name: .customLong("state-dir"), help: "Where the identity and pairings live.") var stateDir: String?

    func run() async throws {
        let store = try Store(stateDir)
        var identity = try store.identity()
        if let name { identity = ClientIdentity(id: identity.id, name: name, key: identity.key) }
        let url: URL
        if let u = URL(string: engine), u.scheme == "https" || u.scheme == "http" {
            url = u
        } else {
            let found = await EngineBrowser.discover(for: .seconds(2))
            guard let match = found.first(where: { EngineOptions.matches(engine, id: $0.engineID ?? "", name: $0.serviceName) }) else {
                throw ValidationError("No engine '\(engine)' found. Try: mes discover")
            }
            url = try await match.resolve()
        }
        let pairing = try await Pairing.begin(baseURL: url, identity: identity)
        print("Pairing with \(pairing.engine.name) as \"\(identity.name)\".")
        print("Check that the engine shows this code, then approve it there:\n\n    \(pairing.code)\n")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            switch try await pairing.confirm(wait: min(60, max(1, Int(deadline.timeIntervalSinceNow)))) {
            case .approved(let engine):
                try store.save(engine)
                print("Paired. \(engine.engineName) (\(engine.engineID)) is saved; its certificate is pinned.")
                return
            case .awaitingApproval:
                note("Still waiting for approval on the engine…")
            }
        }
        throw ValidationError("Not approved within \(timeout) s.")
    }
}

struct Unpair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove this client's pairing from an engine, and forget it.")
    @Argument(help: "A paired engine's id or name.") var engine: String
    @Option(name: .customLong("state-dir")) var stateDir: String?

    func run() async throws {
        let store = try Store(stateDir)
        guard let paired = store.pairings().first(where: { EngineOptions.matches(engine, id: $0.engineID, name: $0.engineName) }) else {
            throw ValidationError("No paired engine '\(engine)'.")
        }
        do { try await Pairing.unpair(paired) } catch { note("The engine didn't confirm (\(error)); forgetting it anyway.") }
        try store.remove(paired.engineID)
        print("Unpaired \(paired.engineName).")
    }
}

struct Engines: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired engines.")
    @Option(name: .customLong("state-dir")) var stateDir: String?

    func run() async throws {
        let paired = try Store(stateDir).pairings()
        if paired.isEmpty { print("No paired engines."); return }
        for p in paired { print("\(p.engineName) (\(p.engineID))\n  \(p.baseURL.absoluteString)\n  pinned sha256 \(p.fingerprintSHA256)") }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The engine's handshake document and health.")
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let engine = try await options.connect()
        let info = try await engine.engineInfo()
        let health = try await engine.health()
        if json { print(Format.json(["engine": try JSONValue(encoding: info), "health": try JSONValue(encoding: health)])); return }
        print("\(info.name) (\(info.id)) · \(info.implementation.name) \(info.implementation.version)")
        print("  \(engine.baseURL.absoluteString) · \(info.auth.rawValue)\(info.tls.map { " · tls \($0.fingerprintSHA256.prefix(16))…" } ?? "")")
        print("  profiles: \(info.profiles.map { "\($0.id) \($0.versions.joined(separator: "/"))" }.joined(separator: ", "))")
        print("  features: \(info.features.map(\.rawValue).joined(separator: ", "))")
        print("  health: \(health.status.rawValue) · queue \(health.queueDepth)\(health.running.map { " · running \($0)" } ?? "")")
    }
}

struct Ops: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The operations the engine offers, with their models and licences.")
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await options.connect().operations()
        if json { print(Format.json(list)); return }
        for d in list.operations {
            print("\(d.operation)  \(d.title)")
            for m in d.models { print("    \(m.id)\(m.isDefault == true ? " (default)" : "") · \(Format.license(m.license))") }
        }
    }
}

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "An operation's inputs, parameters and models.")
    @Argument(help: "An operation, e.g. image.fill.") var operation: String
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print the descriptor as JSON.") var json = false

    func run() async throws {
        let list = try await options.connect().operations()
        guard let d = list.operations.first(where: { $0.operation == operation }) else {
            throw ValidationError("No operation \(operation). Try: mes ops")
        }
        if json { print(Format.json(d)); return }
        print("\(d.operation) — \(d.title)\(d.summary.map { "\n  \($0)" } ?? "")\n\nInputs (--input name=…):")
        for i in d.inputs {
            let count = i.max.map { $0 > 1 ? ", up to \($0)" : "" } ?? (i.kind == .text ? "" : ", several")
            print("  \(i.name)  \(i.kind.rawValue)\(i.required ? ", required" : "")\(count)\(i.notes.map { " — \($0)" } ?? "")")
        }
        print("\nParameters (--param name=…):")
        let properties = d.params["properties"]?.objectValue ?? [:]
        for (name, schema) in properties.sorted(by: { $0.key < $1.key }) {
            var facts: [String] = []
            if let t = schema["type"]?.stringValue { facts.append(t) }
            if let e = schema["enum"]?.arrayValue { facts.append(e.compactMap(\.stringValue).joined(separator: "|")) }
            if let lo = schema["minimum"]?.numberValue, let hi = schema["maximum"]?.numberValue { facts.append("\(Self.n(lo))…\(Self.n(hi))") }
            if let def = schema["default"] { facts.append("default \(Format.json(def))") }
            print("  \(name)  \(facts.joined(separator: " · "))\(schema["description"]?.stringValue.map { " — \($0)" } ?? "")")
        }
        print("\nModels (--model):")
        for m in d.models { print("  \(m.id)\(m.isDefault == true ? " (default)" : "")  \(m.title) · \(Format.license(m.license)) · \(m.qualityTiers.map(\.rawValue).joined(separator: "/"))") }
    }

    static func n(_ d: Double) -> String { d.rounded() == d ? String(Int(d)) : String(d) }
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run an operation: send inputs, follow progress, save the outputs, confirm.",
        discussion: """
            Inputs follow the operation's descriptor (mes describe <operation>): text as is, media as file paths, \
            data as JSON. Repeat a name for several values. Parameters are JSON when they parse (seed=3, \
            strength=0.6) and strings otherwise; size also takes WxH.
            """)
    @Argument(help: "An operation, e.g. image.generate.") var operation: String
    @Option(name: .shortAndLong, help: "An input as name=value. Repeatable.") var input: [String] = []
    @Option(name: .shortAndLong, help: "A parameter as name=value. Repeatable.") var param: [String] = []
    @Option(help: "A model id from the descriptor (default: the engine chooses).") var model: String?
    @Flag(help: "Only models whose licence allows commercial use.") var commercialOnly = false
    @Flag(help: "Allow remote providers, which may bill.") var allowRemote = false
    @Option(name: .shortAndLong, help: "Directory for the outputs.") var out = "."
    @Flag(help: "Keep the outputs on the engine (confirm later with mes confirm).") var noConfirm = false
    @Flag(help: "Print the final job as JSON.") var json = false
    @OptionGroup var options: EngineOptions

    func run() async throws {
        let engine = try await options.connect()
        let info = try await engine.engineInfo()
        guard let descriptor = try await engine.operations().operations.first(where: { $0.operation == operation }) else {
            throw ValidationError("\(info.name) has no operation \(operation). Try: mes ops")
        }
        let inputs = try await Arguments.inputs(input, descriptor: descriptor, engine: engine, inlineLimit: info.limits.maxInlineBytes)
        var params: [String: JSONValue] = [:]
        for pair in param {
            let (name, value) = try Arguments.split(pair)
            params[name] = Arguments.param(name, value)
        }
        let policy = Policy(license: commercialOnly ? .commercialUse : nil, remote: allowRemote ? .allow : nil)
        let request = JobRequest(operation: operation, inputs: inputs, params: params.isEmpty ? nil : params, model: model,
                                 policy: commercialOnly || allowRemote ? policy : nil)
        let reporter = ProgressReporter()
        let job = try await engine.run(request) { await reporter.report($0) }
        if json { print(Format.json(job)) } else { print(Format.job(job)) }
        guard job.outcome == .succeeded, job.state == .holding else { throw ExitCode.failure }
        let files = try await engine.downloadAll(job, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true))
        for file in files { print("saved \(file.path)") }
        if noConfirm {
            note("Outputs kept on the engine; confirm with: mes confirm \(job.id)")
        } else {
            _ = try await engine.confirm(job.id)
        }
    }
}

/// Progress lines on standard error: each state, and progress in 10% steps.
actor ProgressReporter {
    private var lastDecile = -1

    func report(_ event: Event) {
        switch event.type {
        case .state: note("· \(event.data["state"]?.stringValue ?? "")")
        case .plan:
            if let model = event.data["model"]?["id"]?.stringValue { note("· model \(model)") }
        case .progress:
            let fraction = event.data["fraction"]?.numberValue ?? 0
            let decile = Int(fraction * 10)
            if decile > lastDecile {
                lastDecile = decile
                let step = event.data["step"]?.intValue.map { s in " (\(s)/\(event.data["steps"]?.intValue ?? 0))" } ?? ""
                note("· \(event.data["stage"]?.stringValue ?? "running") \(decile * 10)%\(step)")
            }
        case .warning: note("· warning \(event.data["code"]?.stringValue ?? ""): \(event.data["message"]?.stringValue ?? "")")
        default: break
        }
    }
}

struct Jobs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "This client's jobs on the engine.")
    @Option(help: "Only jobs in this state (received, fetching, waiting, running, holding, purged).") var state: String?
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let filter = try state.map { s in
            guard let st = JobState(rawValue: s) else { throw ValidationError("Unknown state \(s).") }
            return st
        }
        let jobs = try await options.connect().jobs(state: filter)
        if json { print(Format.json(jobs)); return }
        if jobs.isEmpty { print("No jobs.") }
        for job in jobs { print(Format.job(job)) }
    }
}

struct Get: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "A job's snapshot, optionally waiting for it to change.")
    @Argument var job: String
    @Option(help: "Seconds to wait for a state change (≤ 60).") var wait = 0
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let snapshot = try await options.connect().job(job, wait: wait)
        print(json ? Format.json(snapshot) : Format.job(snapshot))
    }
}

struct Download: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a held job's outputs (checked against their SHA-256).")
    @Argument var job: String
    @Option(name: .shortAndLong, help: "Directory for the outputs.") var out = "."
    @OptionGroup var options: EngineOptions

    func run() async throws {
        let engine = try await options.connect()
        let snapshot = try await engine.job(job, wait: 0)
        guard snapshot.state == .holding else { throw ValidationError("\(job) is \(snapshot.state.rawValue); only held jobs have outputs.") }
        for file in try await engine.downloadAll(snapshot, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)) {
            print("saved \(file.path)")
        }
    }
}

struct Confirm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tell the engine you have a job's outputs; it purges them.")
    @Argument var job: String
    @OptionGroup var options: EngineOptions

    func run() async throws { print(Format.job(try await options.connect().confirm(job))) }
}

struct Release: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Cancel a job, or discard a held job's outputs.")
    @Argument var job: String
    @OptionGroup var options: EngineOptions

    func run() async throws { print(Format.job(try await options.connect().release(job))) }
}
