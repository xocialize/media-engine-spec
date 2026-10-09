import Foundation
import MESClientKit
import MESCore

/// One conformance test: an id from the catalogue, what it checks, where the spec says so, when it applies, and the
/// check itself (which throws a `Failure` to fail).
public struct ConformanceTest: Sendable {
    public let id: String
    public let title: String
    public let spec: String
    /// Nil when the test applies to this engine; otherwise why it's skipped (a feature not claimed, an operation not
    /// offered, a mode).
    let applies: @Sendable (Probe) -> String?
    let run: @Sendable (Probe) async throws -> Note?

    init(_ id: String, _ title: String, spec: String, applies: @escaping @Sendable (Probe) -> String? = { _ in nil },
         run: @escaping @Sendable (Probe) async throws -> Note?) {
        self.id = id; self.title = title; self.spec = spec; self.applies = applies; self.run = run
    }
}

/// A passing test's remark: something conformant but worth a reader's attention.
public struct Note: Sendable { public let text: String; public init(_ text: String) { self.text = text } }

/// Everything a test may use: the wire, what the engine said about itself, and helpers for jobs and media.
public final class Probe: @unchecked Sendable {
    public let wire: Wire
    public let info: EngineInfo
    public let operations: [Descriptor]
    public let schemas = Schemas()
    public let options: Options
    let infoBody: Data

    public struct Options: Sendable {
        /// Observe output expiry (BASE-071) when the engine's outputs TTL is at most this many seconds.
        public var maxTTLWait: Int = 30
        /// Pairing credentials were obtained by the suite, so BASE-090 can check them (and unpair at the end).
        public var pairing: PairingRun?
        /// This machine's address as the engine sees it, for grants (BASE-040). Loopback engines need none.
        public var grantHost: String?
        public init() {}
    }

    /// What the suite saw while pairing (Base §5), checked by BASE-090.
    public struct PairingRun: Sendable {
        public var pairingID: String
        public var token: String
        public init(pairingID: String, token: String) { self.pairingID = pairingID; self.token = token }
    }

    init(wire: Wire, info: EngineInfo, infoBody: Data, operations: [Descriptor], options: Options) {
        self.wire = wire; self.info = info; self.infoBody = infoBody; self.operations = operations; self.options = options
    }

    /// Connects: reads the handshake and the descriptors (both re-checked by BASE-001 and BASE-010).
    public static func connect(_ wire: Wire, options: Options = Options()) async throws -> Probe {
        let reply = try await wire.send("GET", "engine")
        guard reply.status == 200 else { throw Failure("GET engine answered \(reply.status); can't start.") }
        let info = try reply.decode(EngineInfo.self)
        let ops = try await wire.send("GET", "operations")
        guard ops.status == 200 else {
            throw Failure("GET operations answered \(ops.status)\(ops.status == 401 ? ": a paired engine needs --token and --pin, --paired-state, or --pair" : "").")
        }
        return Probe(wire: wire, info: info, infoBody: reply.body, operations: try ops.decode(OperationsList.self).operations,
                     options: options)
    }

    public func has(_ feature: Feature) -> Bool { info.features.contains(feature) }
    public func descriptor(_ operation: String) -> Descriptor? { operations.first { $0.operation == operation } }
    public var isLoopback: Bool { ["127.0.0.1", "localhost", "::1", "[::1]"].contains(wire.baseURL.host ?? "") }

    // MARK: - Requests

    /// A minimal valid request for `d`: text for every text input, the fixture image or mask for required media
    /// inputs, no params. Nil when it needs something the suite can't make (a required data input, video, audio).
    public func minimalRequest(_ d: Descriptor, image: Data = Fixtures.png(), mask: Data = Fixtures.mask()) -> JobRequest? {
        var inputs: [String: RequestInput] = [:]
        for spec in d.inputs {
            switch spec.kind {
            case .text: inputs[spec.name] = .text("a lighthouse on a cliff at dusk")
            case .image where spec.required: inputs[spec.name] = .one(.inline(mediaType: "image/png", data: image))
            case .mask where spec.required: inputs[spec.name] = .one(.inline(mediaType: "image/png", data: mask))
            default: if spec.required { return nil }
            }
        }
        return JobRequest(operation: d.operation, inputs: inputs)
    }

    /// The operation Base tests use: one the suite can drive whose first output is media, preferring text-only inputs.
    public var baseOperation: (Descriptor, JobRequest)? {
        let candidates = operations.compactMap { d in minimalRequest(d).map { (d, $0) } }
            .filter { d, _ in d.outputs.first.map { $0.kind != .data } ?? false }
        return candidates.first { d, _ in d.inputs.allSatisfy { $0.kind == .text || !$0.required } } ?? candidates.first
    }

    /// Submits (expecting 201) and long-polls until the job leaves the active states.
    public func run(_ request: JobRequest, timeout: TimeInterval = 180, idempotencyKey: String? = nil) async throws -> Job {
        var headers: [String: String] = [:]
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        let reply = try await wire.json("POST", "jobs", request, headers: headers)
        try expect(reply, 201, "POST jobs (\(request.operation))", schemas: schemas)
        return try await settle(try reply.decode(Job.self), timeout: timeout)
    }

    public func settle(_ job: Job, timeout: TimeInterval = 180) async throws -> Job {
        var current = job
        let deadline = Date().addingTimeInterval(timeout)
        while [.received, .fetching, .waiting, .running].contains(current.state) {
            try check(Date() < deadline, "\(job.id) was still \(current.state.rawValue) after \(Int(timeout)) s.")
            let reply = try await wire.send("GET", "jobs/\(job.id)?wait=10", timeout: 40)
            try expect(reply, 200, "GET jobs/\(job.id)", schemas: schemas)
            current = try reply.decode(Job.self)
        }
        return current
    }

    /// Runs and requires success, returning the held job.
    public func succeed(_ request: JobRequest) async throws -> Job {
        let job = try await run(request)
        try check(job.state == .holding && job.outcome == .succeeded,
                  "\(request.operation) didn't succeed: \(job.state.rawValue) \(job.outcome?.rawValue ?? "") \(job.error.map { "\($0.code): \($0.message)" } ?? "")")
        return job
    }

    public func output(_ job: Job, _ index: Int = 0) async throws -> (Output, Data) {
        guard let output = job.result?.outputs.first(where: { $0.index == index }) else { throw Failure("\(job.id) has no output \(index).") }
        let reply = try await wire.send("GET", "jobs/\(job.id)/outputs/\(index)")
        try expect(reply, 200, "GET output \(index) of \(job.id)", schemas: schemas)
        return (output, reply.body)
    }

    public func confirm(_ job: Job) async {
        _ = try? await wire.send("POST", "jobs/\(job.id)/confirm")
    }
}

// MARK: - Running and reporting

public struct TestResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case pass, fail, skip }
    public var id: String
    public var title: String
    public var spec: String
    public var status: Status
    public var detail: String?
    public var milliseconds: Int
}

public struct ConformanceReport: Codable, Sendable {
    public var suite = "MES conformance \(Catalogue.version)"
    public var engine: EngineSummary
    public var startedAt: Date
    public var results: [TestResult]

    public struct EngineSummary: Codable, Sendable {
        public var id: String
        public var name: String
        public var implementation: String
        public var url: String
        public var auth: String
        public var features: [String]
        public var profiles: [String]
    }

    public var passed: Int { results.filter { $0.status == .pass }.count }
    public var failed: Int { results.filter { $0.status == .fail }.count }
    public var skipped: Int { results.filter { $0.status == .skip }.count }
    /// Base 0.1 conformance: no failing BASE test (skips are features the engine doesn't claim).
    public var conformsToBase: Bool { !results.contains { $0.id.hasPrefix("BASE") && $0.status == .fail } }
    /// Image 0.1 conformance for the operations offered.
    public var conformsToImage: Bool? {
        let image = results.filter { $0.id.hasPrefix("IMAGE") }
        guard image.contains(where: { $0.status != .skip }) else { return nil }
        return !image.contains { $0.status == .fail }
    }
}

public enum ConformanceRunner {
    /// Runs `tests` (default: the whole catalogue) in catalogue order and reports.
    public static func run(_ probe: Probe, only: Set<String>? = nil,
                           progress: @Sendable (TestResult) -> Void = { _ in }) async -> ConformanceReport {
        let started = Date()
        var results: [TestResult] = []
        for test in Catalogue.all where only?.contains(test.id) ?? true {
            let t0 = Date()
            var result = TestResult(id: test.id, title: test.title, spec: test.spec, status: .pass, detail: nil, milliseconds: 0)
            if let reason = test.applies(probe) {
                result.status = .skip
                result.detail = reason
            } else {
                do {
                    result.detail = try await test.run(probe)?.text
                } catch {
                    result.status = .fail
                    result.detail = "\(error)"
                }
            }
            result.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
            progress(result)
            results.append(result)
        }
        let info = probe.info
        return ConformanceReport(
            engine: .init(id: info.id, name: info.name, implementation: "\(info.implementation.name) \(info.implementation.version)",
                          url: probe.wire.baseURL.absoluteString, auth: info.auth.rawValue, features: info.features.map(\.rawValue),
                          profiles: info.profiles.map { "\($0.id) \($0.versions.joined(separator: "/"))" }),
            startedAt: started, results: results)
    }
}

extension ConformanceReport {
    /// The report as Markdown, for people.
    public var markdown: String {
        var lines = [
            "# MES conformance report", "",
            "| | |", "|---|---|",
            "| **Engine** | \(engine.name) (`\(engine.id)`) · \(engine.implementation) |",
            "| **URL** | \(engine.url) · \(engine.auth) |",
            "| **Profiles** | \(engine.profiles.joined(separator: ", ")) |",
            "| **Features** | \(engine.features.joined(separator: ", ")) |",
            "| **Suite** | \(suite) · \(MESJSON.timestamp(startedAt)) |",
            "| **Result** | \(passed) passed · \(failed) failed · \(skipped) skipped |",
            "| **Base 0.1** | \(conformsToBase ? "✅ conforms" : "❌ does not conform") |",
        ]
        if let image = conformsToImage { lines.append("| **Image 0.1** | \(image ? "✅ conforms for the operations offered" : "❌ does not conform") |") }
        lines += ["", "| Test | Checks | Spec | Result |", "|---|---|---|---|"]
        for r in results {
            let mark = switch r.status { case .pass: "✅ pass"; case .fail: "❌ **fail**"; case .skip: "➖ skip" }
            let detail = r.detail.map { ": " + $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") } ?? ""
            lines.append("| \(r.id) | \(r.title) | \(r.spec) | \(mark)\(detail) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension Probe {
    /// Pairs as `mes-conformance` (Base §5), waiting for the engine's operator, and returns a wire carrying the token
    /// and pinned certificate, plus what BASE-090 checks. `showCode` gets the code to display.
    public static func pair(baseURL: URL, attempts: Int = 10, showCode: @Sendable (String) -> Void = { _ in })
        async throws -> (Wire, PairingRun) {
        let pairing = try await Pairing.begin(baseURL: baseURL, identity: .generate(name: "mes-conformance"))
        showCode(pairing.code)
        for _ in 0..<attempts {
            if case .approved(let engine) = try await pairing.confirm(wait: 30) {
                return (Wire(baseURL: baseURL, token: engine.token, pinned: pairing.engineFingerprint),
                        PairingRun(pairingID: pairing.pairingID, token: engine.token))
            }
        }
        throw Failure("The pairing wasn't approved.")
    }
}
