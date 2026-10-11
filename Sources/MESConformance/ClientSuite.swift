import Foundation
import MESCore
import MESEngineKit
import MockEngineCore

// Client conformance (Base §16): the mock engine runs in scenario mode, records every request, and injects the
// situations a client must handle (busy, no capacity, a failed or cancelled job, an unknown error, outputs gone). The
// client does one task per scenario: generate an image from a prompt and save it. It's judged from the engine's side:
// what it sent, when, what it left behind, and how it exited.

/// A client the suite can drive: given an engine URL and an output directory, it does the task and exits.
public struct ClientUnderTest: Sendable {
    public let name: String
    let run: @Sendable (_ engine: URL, _ out: URL) async -> ProcessResult

    /// The reference CLI: `mes run image.generate -i prompt=… -p size=64x48 -p seed=7 --engine <url> -o <out>`.
    public static func mes(_ executable: String) -> ClientUnderTest {
        ClientUnderTest(name: "mes (\(executable))") { engine, out in
            let state = out.appendingPathComponent(".mes-state").path
            return await runProcess([executable, "run", "image.generate", "-i", "prompt=\(ClientSuite.prompt)", "-p", "size=64x48",
                                     "-p", "seed=7", "--engine", engine.absoluteString, "-o", out.path, "--state-dir", state])
        }
    }

    /// Any command-line client, as a shell template with `{url}`, `{prompt}` and `{out}` (each shell-quoted).
    public static func command(_ template: String) -> ClientUnderTest {
        ClientUnderTest(name: template) { engine, out in
            let command = template.replacingOccurrences(of: "{url}", with: quote(engine.absoluteString))
                .replacingOccurrences(of: "{prompt}", with: quote(ClientSuite.prompt))
                .replacingOccurrences(of: "{out}", with: quote(out.path))
            return await runProcess(["/bin/zsh", "-c", command])
        }
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var signalled: Bool
    public var timedOut: Bool
    public var output: String
}

/// Runs a process to completion (or `timeout`), capturing stdout and stderr together.
func runProcess(_ arguments: [String], timeout: TimeInterval = 90) async -> ProcessResult {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = OutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        do { try process.run() } catch {
            return ProcessResult(exitCode: 127, signalled: false, timedOut: false, output: "couldn't start: \(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let timedOut = process.isRunning
        if timedOut { process.terminate(); process.waitUntilExit() }
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return ProcessResult(exitCode: process.terminationStatus, signalled: process.terminationReason == .uncaughtSignal,
                             timedOut: timedOut, output: collected.text)
    }.value
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// What the scenario engine saw.
actor Recorder {
    struct Entry: Sendable { let request: InterceptedRequest; let status: Int }
    private(set) var entries: [Entry] = []
    private(set) var injected: [InterceptedRequest] = []
    private var counts: [String: Int] = [:]

    func record(_ request: InterceptedRequest, _ status: Int) {
        guard request.headers[ClientSuite.operatorHeader.lowercased()] == nil else { return }
        entries.append(Entry(request: request, status: status))
    }

    /// Counts requests matching `key`, returning the new count (for "the first POST jobs" rules).
    func count(_ key: String) -> Int { counts[key, default: 0] += 1; return counts[key]! }
    func noteInjected(_ request: InterceptedRequest) { injected.append(request) }
}

/// One situation the client must handle.
struct ClientScenario: Sendable {
    let id: String
    let title: String
    var stepDelay: Duration = .milliseconds(150)
    var steps = 6
    var failRun = false
    /// Answers a request instead of the engine (and the recorder notes it).
    var inject: (@Sendable (InterceptedRequest, Recorder) async -> InjectedResponse?)?
    /// Something the engine's operator does while the client runs (cancelling its job).
    var operatorAction: (@Sendable (Wire) async -> Void)?
}

/// What a scenario produced, for the checks.
struct ScenarioRun: Sendable {
    let scenario: ClientScenario
    let result: ProcessResult
    let entries: [Recorder.Entry]
    let injected: [InterceptedRequest]
    /// The client's jobs as the engine sees them after it exited.
    let jobsAfter: [Job]
    let descriptors: [Descriptor]
    let out: URL

    func requests(_ method: String, _ prefix: String) -> [Recorder.Entry] {
        entries.filter { $0.request.method == method && $0.request.path.hasPrefix(prefix) }
    }
    var jobPosts: [Recorder.Entry] { requests("POST", "jobs").filter { $0.request.path == "jobs" } }
    var outputGets: [Recorder.Entry] { requests("GET", "jobs/").filter { $0.request.path.contains("/outputs/") } }
    var exitedCleanly: Bool { !result.signalled && !result.timedOut && result.exitCode < 128 }
    var summary: String { "exit \(result.exitCode)\(result.signalled ? " (signal)" : "")\(result.timedOut ? " (timed out)" : "")" }
}

public enum ClientSuite {
    static let prompt = "a lighthouse at dusk"
    /// Requests the suite itself makes (as the engine's operator) carry this header and aren't held against the client.
    static let operatorHeader = "X-MES-Conformance-Operator"

    static let scenarios: [ClientScenario] = [
        ClientScenario(id: "normal", title: "A job that takes about a second, with progress"),
        ClientScenario(id: "busy", title: "The first submission answers 429 busy with Retry-After: 2", inject: { request, recorder in
            guard request.method == "POST", request.path == "jobs", await recorder.count("post-jobs") == 1 else { return nil }
            await recorder.noteInjected(request)
            return .error(429, code: "busy", message: "Scenario: the queue is full.", headers: ["Retry-After": "2"])
        }),
        ClientScenario(id: "no-capacity", title: "The first submission answers 503 no_capacity with Retry-After: 2", inject: { request, recorder in
            guard request.method == "POST", request.path == "jobs", await recorder.count("post-jobs") == 1 else { return nil }
            await recorder.noteInjected(request)
            return .error(503, code: "no_capacity", message: "Scenario: no capacity right now.", headers: ["Retry-After": "2"])
        }),
        ClientScenario(id: "failed", title: "The job fails (engine_error)", failRun: true),
        ClientScenario(id: "cancelled", title: "The engine's operator cancels the job while it runs", stepDelay: .milliseconds(500), steps: 20,
                       operatorAction: { wire in
            struct List: Decodable { var jobs: [Job] }
            for _ in 0..<100 {
                let reply = try? await wire.send("GET", "jobs", headers: [ClientSuite.operatorHeader: "1"])
                if let job = (try? reply?.decode(List.self))?.jobs.first(where: { $0.state == .running }) {
                    try? await Task.sleep(for: .milliseconds(700))
                    _ = try? await wire.send("DELETE", "jobs/\(job.id)", headers: [ClientSuite.operatorHeader: "1"])
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }),
        ClientScenario(id: "unknown-error", title: "Submission answers 422 with an error code the client can't know", inject: { request, recorder in
            guard request.method == "POST", request.path == "jobs" else { return nil }
            await recorder.noteInjected(request)
            return .error(422, code: "x_conformance_future_code", message: "Scenario: a code from a later version of the spec.")
        }),
        ClientScenario(id: "gone", title: "Outputs answer 410 gone (they expired before collection)", inject: { request, recorder in
            guard request.method == "GET", request.path.contains("/outputs/") else { return nil }
            await recorder.noteInjected(request)
            return .error(410, code: "gone", message: "Scenario: the outputs expired.")
        }),
    ]

    /// Runs one scenario: a fresh mock engine on a free loopback port, the client against it, then the evidence.
    static func run(_ scenario: ClientScenario, client: ClientUnderTest) async throws -> ScenarioRun {
        let recorder = Recorder()
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-client-scenario-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spool) }
        var config = EngineConfiguration(id: "eng_client_conformance", name: "Client Conformance (\(scenario.id))",
                                         implementationName: "mes-mock-engine", implementationVersion: "0.1.0", spoolDirectory: spool)
        config.advertise = false
        config.sweepInterval = .milliseconds(200)
        config.logLevel = .critical
        let inject = scenario.inject
        config.interceptor = { request in await inject?(request, recorder) }
        config.responseObserver = { request, status in await recorder.record(request, status) }
        let engine = ScenarioEngine(mock: MockImageEngine(stepDelay: scenario.stepDelay, steps: scenario.steps), failRun: scenario.failRun)
        let server = MESEngineServer(engine: engine, configuration: config)
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = try await server.makeApplication { port in continuation.yield(port) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mes-client-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        return try await withThrowingTaskGroup(of: ScenarioRun?.self) { group in
            // No signal handling: this engine lives inside `mes-conformance` (or a test), and a trapped SIGINT stays
            // ignored after the scenario, so Ctrl-C would no longer stop the suite.
            group.addTask { try await app.runService(gracefulShutdownSignals: []); return nil }
            var it = ports.makeAsyncIterator()
            guard let port = await it.next() else { throw Failure("The scenario engine didn't start.") }
            let url = URL(string: "http://127.0.0.1:\(port)/mes/v0")!
            let operatorWire = Wire(baseURL: url)
            let action = scenario.operatorAction.map { action in Task { await action(operatorWire) } }
            let result = await client.run(url, out)
            action?.cancel()
            struct List: Decodable { var jobs: [Job] }
            let jobs = (try? (try await operatorWire.send("GET", "jobs", headers: [operatorHeader: "1"])).decode(List.self).jobs) ?? []
            let ops = (try? (try await operatorWire.send("GET", "operations", headers: [operatorHeader: "1"])).decode(OperationsList.self).operations) ?? []
            let run = ScenarioRun(scenario: scenario, result: result, entries: await recorder.entries, injected: await recorder.injected,
                                  jobsAfter: jobs, descriptors: ops, out: out)
            group.cancelAll()
            return run
        }!
    }

    /// Runs every scenario and every check, in catalogue order.
    public static func run(client: ClientUnderTest, only: Set<String>? = nil,
                           progress: @Sendable (TestResult) -> Void = { _ in }) async -> ClientReport {
        let started = Date()
        var runs: [String: ScenarioRun] = [:]
        var failures: [String: String] = [:]
        var results: [TestResult] = []
        for check in ClientChecks.all where only?.contains(check.id) ?? true {
            let t0 = Date()
            var result = TestResult(id: check.id, title: check.title, spec: check.spec, status: .pass, detail: nil, milliseconds: 0)
            if runs[check.scenario] == nil, failures[check.scenario] == nil, let scenario = scenarios.first(where: { $0.id == check.scenario }) {
                do { runs[check.scenario] = try await run(scenario, client: client) } catch { failures[check.scenario] = "\(error)" }
            }
            if let run = runs[check.scenario] {
                do { result.detail = try check.evaluate(run)?.text } catch {
                    result.status = .fail
                    result.detail = "\(error)"
                }
            } else {
                result.status = .fail
                result.detail = "The scenario couldn't run: \(failures[check.scenario] ?? "unknown")"
            }
            result.milliseconds = Int(Date().timeIntervalSince(t0) * 1000)
            progress(result)
            results.append(result)
        }
        return ClientReport(client: client.name, startedAt: started, results: results)
    }
}

/// The mock engine, optionally failing every job (the `failed` scenario).
struct ScenarioEngine: MediaEngine {
    let mock: MockImageEngine
    let failRun: Bool
    func descriptors() async -> [Descriptor] { await mock.descriptors() }
    func residentModels() async -> [String] { await mock.residentModels() }
    func run(_ context: RunContext) async throws -> RunOutput {
        if failRun {
            await context.reporter.progress(.running, step: 1, steps: 2)
            throw MESError(.engineError, "Scenario: the model failed.")
        }
        return try await mock.run(context)
    }
}

public struct ClientReport: Codable, Sendable {
    public var suite = "MES client conformance \(Catalogue.version)"
    public var client: String
    public var startedAt: Date
    public var results: [TestResult]
    public var passed: Int { results.filter { $0.status == .pass }.count }
    public var failed: Int { results.filter { $0.status == .fail }.count }
    public var conforms: Bool { failed == 0 }

    public var markdown: String {
        var lines = ["# MES client conformance report", "", "| | |", "|---|---|",
                     "| **Client** | `\(client)` |", "| **Suite** | \(suite) · \(MESJSON.timestamp(startedAt)) |",
                     "| **Result** | \(passed) passed · \(failed) failed |",
                     "| **Base 0.1 (client)** | \(conforms ? "✅ conforms" : "❌ does not conform") |", "",
                     "| Test | Checks | Spec | Result |", "|---|---|---|---|"]
        for r in results {
            let mark = r.status == .fail ? "❌ **fail**" : "✅ pass"
            let detail = r.detail.map { ": " + $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") } ?? ""
            lines.append("| \(r.id) | \(r.title) | \(r.spec) | \(mark)\(detail) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
