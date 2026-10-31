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
              mes voices audio.speak mock-presets
              mes run audio.speak -i text="Hello." -i voice_ref=asset:clip.wav --stream
            """,
        version: MESClientKit.baseVersion,
        subcommands: [Discover.self, Pair.self, Unpair.self, Engines.self, Info.self, Ops.self, Describe.self, Voices.self,
                      Run.self, Jobs.self, Get.self, Download.self, Confirm.self, Release.self, Assets.self])

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
        for m in d.models {
            var facts = [m.title, Format.license(m.license), m.qualityTiers.map(\.rawValue).joined(separator: "/")]
            if m.streams { facts.append("streams") }
            if m.voiceCount > 0 { facts.append("\(m.voiceCount) voices (mes voices \(d.operation) \(m.id))") }
            print("  \(m.id)\(m.isDefault == true ? " (default)" : "")  \(facts.joined(separator: " · "))")
        }
        let streamable = d.outputs.filter { $0.stream != nil }
        if !streamable.isEmpty {
            print("\nStreams (--stream): \(streamable.map { "\($0.name) as \($0.stream!.encodings.map(\.rawValue).joined(separator: "|"))" }.joined(separator: ", "))")
        }
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

            A media input given as asset:<id> names an asset already on the engine (mes assets); asset:<file> keeps \
            the file there as an asset (--asset-ttl) and names it, and sends it again if the engine has lost it.

            --stream asks for every output that can to arrive as chunks while the job runs, and writes each to \
            <job>-<output>.stream.wav as the chunks come; the finished output is still saved as usual.
            """)
    @Argument(help: "An operation, e.g. image.generate.") var operation: String
    @Option(name: .shortAndLong, help: "An input as name=value. Repeatable.") var input: [String] = []
    @Option(name: .shortAndLong, help: "A parameter as name=value. Repeatable.") var param: [String] = []
    @Option(help: "A model id from the descriptor (default: the engine chooses).") var model: String?
    @Flag(help: "Only models whose licence allows commercial use.") var commercialOnly = false
    @Flag(help: "Allow remote providers, which may bill.") var allowRemote = false
    @Option(name: .shortAndLong, help: "Directory for the outputs.") var out = "."
    @Flag(help: "Keep the outputs on the engine (confirm later with mes confirm).") var noConfirm = false
    @Flag(help: "Stream every output that can, writing the chunks as they arrive.") var stream = false
    @Option(help: "With --stream, the encoding: pcm_s16le or pcm_f32le (default: the output's first).") var streamEncoding: String?
    @Option(help: "Seconds an asset:<file> input is kept on the engine.") var assetTtl = 3600
    @Flag(help: "Print the final job as JSON.") var json = false
    @OptionGroup var options: EngineOptions

    func run() async throws {
        let engine = try await options.connect()
        let info = try await engine.engineInfo()
        guard let descriptor = try await engine.operations().operations.first(where: { $0.operation == operation }) else {
            throw ValidationError("\(info.name) has no operation \(operation). Try: mes ops")
        }
        let library = AssetLibrary(engine: engine, ttlSeconds: assetTtl)
        let inputs = try await Arguments.inputs(input, descriptor: descriptor, engine: engine, inlineLimit: info.limits.maxInlineBytes,
                                                assets: library)
        var params: [String: JSONValue] = [:]
        for pair in param {
            let (name, value) = try Arguments.split(pair)
            params[name] = Arguments.param(name, value)
        }
        let policy = Policy(license: commercialOnly ? .commercialUse : nil, remote: allowRemote ? .allow : nil)
        let encoding = try streamEncoding.map { e in
            guard let encoding = StreamEncoding(rawValue: e) else { throw ValidationError("Unknown stream encoding \(e).") }
            return encoding
        }
        let streams = descriptor.outputs.filter { $0.stream != nil }.map { StreamRequest(output: $0.name, encoding: encoding) }
        if stream, streams.isEmpty { throw ValidationError("\(operation) has no output that streams.") }
        let request = JobRequest(operation: operation, inputs: inputs, params: params.isEmpty ? nil : params, model: model,
                                 policy: commercialOnly || allowRemote ? policy : nil, stream: stream ? streams : nil)
        let reporter = ProgressReporter()
        let directory = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        let job: Job
        if stream {
            let writer = StreamFiles(directory: directory)
            job = try await library.runStreaming(request, onChunk: { try await writer.write($0) }) { await reporter.report($0) }
            for file in try await writer.finish(succeeded: job.outcome == .succeeded) { print("streamed \(file.path)") }
        } else {
            job = try await library.run(request) { await reporter.report($0) }
        }
        if json { print(Format.json(job)) } else { print(Format.job(job)) }
        guard job.outcome == .succeeded, job.state == .holding else { throw ExitCode.failure }
        let files = try await engine.downloadAll(job, to: directory)
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
        case .outputChunk:
            if event.data["final"]?.boolValue == true {
                note("· \(event.data["output"]?.stringValue ?? "output") streamed: \(event.data["index"]?.intValue.map { $0 + 1 } ?? 0) chunks")
            } else if event.data["index"]?.intValue == 0 {
                note("· streaming \(event.data["output"]?.stringValue ?? "output")")
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

/// `--stream`: each output's chunks written to `<job>-<output>.stream.wav` as they arrive (Base §10.1's format for the
/// stream's encoding). A stream left without its final chunk is incomplete (§11 rule 5), and its file is removed.
actor StreamFiles {
    let directory: URL
    private var writers: [String: WAVStreamWriter] = [:]

    init(directory: URL) { self.directory = directory }

    func write(_ chunk: OutputChunk) throws {
        guard let samples = chunk.samples else { return }
        if writers[chunk.output] == nil {
            guard let format = chunk.format, let job = chunk.job else {
                throw MESClientError.unexpected("A chunk of \(chunk.output) arrived before the plan gave its format.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            writers[chunk.output] = try WAVStreamWriter(url: directory.appendingPathComponent("\(job)-\(chunk.output).stream.wav"),
                                                        format: format)
        }
        try writers[chunk.output]?.append(samples)
    }

    func finish(succeeded: Bool) throws -> [URL] {
        defer { writers = [:] }
        let files = try writers.keys.sorted().compactMap { try writers[$0]?.finish() }
        guard succeeded else {
            for file in files { try? FileManager.default.removeItem(at: file) }
            if !files.isEmpty { note("· the job didn't succeed; the partial streams were removed") }
            return []
        }
        return files
    }
}

struct Voices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "A model's preset voices (pass one as --param voice=<id>).")
    @Argument(help: "An operation, e.g. audio.speak.") var operation: String
    @Argument(help: "A model offering voices (mes describe <operation> shows which).") var model: String
    @OptionGroup var options: EngineOptions
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await options.connect().voices(operation: operation, model: model)
        if json { print(Format.json(list)); return }
        for v in list.voices {
            let facts = (v.languages ?? []) + (v.tags ?? [])
            print("\(v.id)  \(v.title)\(facts.isEmpty ? "" : " · \(facts.joined(separator: ", "))")")
            if let notes = v.notes { print("    \(notes)") }
            if let license = v.license { print("    licence: \(Format.license(license))") }
            if let sample = v.sample { print("    sample: \(sample)") }
        }
    }
}

struct Assets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Files this client keeps on the engine for reuse by its jobs (Base §8.1).",
        subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "This client's assets.")
        @OptionGroup var options: EngineOptions
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let assets = try await options.connect().assets()
            if json { print(Format.json(AssetList(assets: assets))); return }
            if assets.isEmpty { print("No assets.") }
            for a in assets { print(Format.asset(a)) }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Keep a file on the engine; prints its id.")
        @Argument(help: "The file.") var file: String
        @Option(help: "Seconds to keep it (the engine grants at most its max_asset_ttl_s).") var ttl = 86_400
        @Option(help: "Its media type (default: from the extension).") var mediaType: String?
        @OptionGroup var options: EngineOptions

        func run() async throws {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ValidationError("No file at \(file).") }
            print(Format.asset(try await options.connect().createAsset(contentsOf: url, mediaType: mediaType, ttl: .seconds(ttl))))
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete assets.")
        @Argument(help: "Asset ids.") var ids: [String]
        @OptionGroup var options: EngineOptions

        func run() async throws {
            let engine = try await options.connect()
            for id in ids {
                try await engine.deleteAsset(id)
                print("deleted \(id)")
            }
        }
    }
}
