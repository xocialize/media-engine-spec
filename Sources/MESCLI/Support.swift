import ArgumentParser
import CryptoKit
import Foundation
import MESClientKit
import MESCore

/// Where `mes` keeps its client identity and pairings: `--state-dir`, `$MES_HOME`, or
/// `~/Library/Application Support/mes`. The key file is 0600, like an SSH key; apps use the keychain instead.
struct Store {
    let directory: URL

    init(_ override: String?) throws {
        let path = override ?? ProcessInfo.processInfo.environment["MES_HOME"]
        directory = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private struct StoredIdentity: Codable { var id: String; var name: String; var key: String }

    /// This client's identity, created on first use and named after the host.
    func identity() throws -> ClientIdentity {
        let file = directory.appendingPathComponent("identity.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let raw = Data(base64Encoded: stored.key), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return ClientIdentity(id: stored.id, name: stored.name, key: key)
        }
        let identity = ClientIdentity.generate(name: "mes on \(Host.current().localizedName ?? "this Mac")")
        let stored = StoredIdentity(id: identity.id, name: identity.name, key: identity.rawKey.base64EncodedString())
        try JSONEncoder().encode(stored).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return identity
    }

    var pairingsFile: URL { directory.appendingPathComponent("engines.json") }

    func pairings() -> [PairedEngine] {
        guard let data = try? Data(contentsOf: pairingsFile) else { return [] }
        return (try? MESJSON.decoder.decode([PairedEngine].self, from: data)) ?? []
    }

    func save(_ engine: PairedEngine) throws {
        var all = pairings().filter { $0.engineID != engine.engineID }
        all.append(engine)
        try write(all)
    }

    func remove(_ engineID: String) throws { try write(pairings().filter { $0.engineID != engineID }) }

    private func write(_ engines: [PairedEngine]) throws {
        try MESJSON.encoder.encode(engines).write(to: pairingsFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pairingsFile.path)
    }
}

/// Options every engine command takes.
struct EngineOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "An engine: a base URL (http://127.0.0.1:17600/mes/v0), or a paired or discovered engine's id or name. Default: $MES_ENGINE, the only paired engine, or the only engine discovered.")
    var engine: String?

    @Option(name: .customLong("state-dir"), help: "Where the identity and pairings live (default $MES_HOME or ~/Library/Application Support/mes).")
    var stateDir: String?

    func store() throws -> Store { try Store(stateDir) }

    /// Picks the engine and returns a connection to it.
    func connect() async throws -> HTTPEngineConnection {
        let store = try store()
        let paired = store.pairings()
        let wanted = engine ?? ProcessInfo.processInfo.environment["MES_ENGINE"]

        if let wanted, let url = URL(string: wanted), url.scheme == "http" || url.scheme == "https" {
            if let p = paired.first(where: { $0.baseURL == url }) { return HTTPEngineConnection(paired: p) }
            return HTTPEngineConnection(baseURL: url)
        }
        if let wanted, let p = paired.first(where: { Self.matches(wanted, id: $0.engineID, name: $0.engineName) }) {
            return HTTPEngineConnection(paired: p)
        }
        if wanted == nil, paired.count == 1 { return HTTPEngineConnection(paired: paired[0]) }

        let found = await EngineBrowser.discover(for: .seconds(2))
        let candidates = wanted.map { w in found.filter { Self.matches(w, id: $0.engineID ?? "", name: $0.serviceName) } } ?? found
        guard candidates.count == 1, let chosen = candidates.first else {
            let names = (paired.map { "\($0.engineName) (\($0.engineID), paired)" }
                + found.map { "\($0.serviceName) (\($0.id))" }).joined(separator: "\n  ")
            throw ValidationError(candidates.isEmpty
                ? "No engine \(wanted.map { "matching '\($0)'" } ?? "found"). Known:\n  \(names.isEmpty ? "none" : names)"
                : "Several engines match; choose one with --engine:\n  \(names)")
        }
        let url = try await chosen.resolve()
        if chosen.auth == .paired {
            guard var p = paired.first(where: { $0.engineID == chosen.engineID }) else {
                throw ValidationError("\(chosen.serviceName) needs pairing: mes pair \(url.absoluteString)")
            }
            p.baseURL = url                                   // addresses change; the pinned certificate doesn't
            return HTTPEngineConnection(paired: p)
        }
        return HTTPEngineConnection(baseURL: url)
    }

    static func matches(_ wanted: String, id: String, name: String) -> Bool {
        id == wanted || name.caseInsensitiveCompare(wanted) == .orderedSame || name.lowercased().hasPrefix(wanted.lowercased())
    }
}

/// `name=value` command-line inputs and parameters.
enum Arguments {
    static func split(_ pair: String) throws -> (String, String) {
        guard let eq = pair.firstIndex(of: "=") else { throw ValidationError("Expected name=value, got '\(pair)'.") }
        return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
    }

    /// A parameter value: JSON when it parses (`3`, `true`, `{"width":512}`), `WxH` for sizes, else a string.
    static func param(_ name: String, _ text: String) -> JSONValue {
        let parts = text.lowercased().split(separator: "x")
        if name == "size", parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
            return ["width": .number(Double(w)), "height": .number(Double(h))]
        }
        return (try? MESJSON.decoder.decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    /// Builds the request's inputs from `name=value` pairs, by each input's kind in the descriptor: text as is, data
    /// as JSON, media as file paths (inline when small, else uploaded). Repeating a name gives several values.
    static func inputs(_ pairs: [String], descriptor: Descriptor, engine: HTTPEngineConnection,
                       inlineLimit: Int) async throws -> [String: RequestInput] {
        var grouped: [String: [String]] = [:]
        var order: [String] = []
        for pair in pairs {
            let (name, value) = try split(pair)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(value)
        }
        var inputs: [String: RequestInput] = [:]
        for name in order {
            guard let spec = descriptor.inputs.first(where: { $0.name == name }) else {
                throw ValidationError("\(descriptor.operation) has no input '\(name)'. Inputs: \(descriptor.inputs.map(\.name).joined(separator: ", ")).")
            }
            let values = grouped[name] ?? []
            switch spec.kind {
            case .text:
                inputs[name] = .text(values.joined(separator: " "))
            case .data:
                let json = try values.map { v in
                    do { return try MESJSON.decoder.decode(JSONValue.self, from: Data(v.utf8)) } catch {
                        throw ValidationError("\(name) takes JSON.")
                    }
                }
                inputs[name] = json.count == 1 ? .one(.data(json[0])) : .many(json.map { .data($0) })
            default:
                var media: [InputValue] = []
                for path in values {
                    let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    guard FileManager.default.fileExists(atPath: file.path) else { throw ValidationError("No file at \(path).") }
                    media.append(try await engine.input(contentsOf: file, inlineLimit: inlineLimit))
                }
                inputs[name] = media.count == 1 ? .one(media[0]) : .many(media)
            }
        }
        return inputs
    }
}

/// Plain-text rendering.
enum Format {
    static func license(_ l: License) -> String {
        let commercial: String = switch l.commercialUse { case .yes: "yes"; case .no: "no"; case .unknown: "unknown" }
        return "\(l.spdx), commercial use \(commercial)"
    }

    static func job(_ job: Job) -> String {
        var lines = ["\(job.id)  \(job.operation)  \(job.state.rawValue)\(job.outcome.map { " (\($0.rawValue))" } ?? "")"]
        if let plan = job.plan { lines.append("  model: \(plan.model.id) · \(license(plan.model.license))") }
        if let p = job.progress, job.outcome == nil {
            lines.append("  progress: \(p.stage.rawValue)\(p.fraction.map { String(format: " %.0f%%", $0 * 100) } ?? "")")
        }
        for w in job.warnings { lines.append("  warning \(w.code): \(w.message)") }
        for o in job.result?.outputs ?? [] {
            lines.append("  output \(o.index) \(o.name): \(o.mediaType)\(o.width.map { " \($0)×\(o.height ?? 0)" } ?? "")")
            if let v = o.value { lines.append("    \(json(v))") }
        }
        if let e = job.error { lines.append("  error \(e.code): \(e.message)") }
        if let expires = job.retention.outputsExpireAt { lines.append("  outputs kept until \(MESJSON.timestamp(expires))") }
        return lines.joined(separator: "\n")
    }

    static func json<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: MESJSON.encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

/// Prints to standard error (progress and notes), keeping standard output for results.
func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
