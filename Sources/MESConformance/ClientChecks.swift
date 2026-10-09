import Foundation
import MESCore

/// A client conformance check (CLIENT-nnn): which scenario it reads, and what it requires of the evidence.
struct ClientCheck: Sendable {
    let id: String
    let title: String
    let spec: String
    let scenario: String
    let evaluate: @Sendable (ScenarioRun) throws -> Note?
}

enum ClientChecks {
    static let schemas = Schemas()

    /// The task should have completed: exit 0, the output fetched.
    static func completed(_ run: ScenarioRun) throws {
        try check(run.exitedCleanly && run.result.exitCode == 0, "the client didn't complete the task: \(run.summary)\n\(run.result.output.suffix(400))")
        try check(run.outputGets.contains { [200, 206].contains($0.status) }, "the client never fetched the output")
    }

    /// The task should have been reported as failed: a non-zero exit that isn't a crash or a hang.
    static func reportedFailure(_ run: ScenarioRun, _ what: String) throws {
        try check(run.exitedCleanly, "the client crashed or hung on \(what): \(run.summary)")
        try check(run.result.exitCode != 0, "the client exited 0 after \(what), as if it had succeeded")
    }

    /// Retry-After honoured: the retry came no sooner than the header said, the client didn't hammer, and the task
    /// completed.
    static func honoursRetryAfter(_ run: ScenarioRun, status: Int) throws -> Note? {
        let posts = run.jobPosts
        guard let refused = posts.first, refused.status == status else {
            throw Failure("expected the first submission to be refused with \(status) (saw \(posts.map(\.status)))")
        }
        guard posts.count >= 2 else { throw Failure("the client didn't retry after \(status) with Retry-After: 2 (\(run.summary))") }
        let wait = posts[1].request.receivedAt.timeIntervalSince(refused.request.receivedAt)
        try check(wait >= 1.9, String(format: "the client retried after %.2f s; Retry-After said 2 s", wait))
        try check(posts.count <= 3, "the client submitted \(posts.count) times")
        try completed(run)
        let keys = posts.map { $0.request.headers["idempotency-key"] }
        if keys.contains(nil) { return Note("Retries carry no Idempotency-Key; with one, a retry can never duplicate a job.") }
        if Set(keys.compactMap { $0 }).count > 1 { return Note("Each retry used a new Idempotency-Key; reusing it makes retries safe.") }
        return nil
    }

    static let all: [ClientCheck] = [
        ClientCheck(id: "CLIENT-001", title: "Every request names the Base version (MES-Version: 0.1)", spec: "§2 rule 3", scenario: "normal") { run in
            let missing = run.entries.filter { $0.request.headers["mes-version"] == nil }
            let wrong = run.entries.compactMap { $0.request.headers["mes-version"] }.filter { $0 != "0.1" }
            try check(wrong.isEmpty, "MES-Version \(Set(wrong).sorted()) isn't a version the engine offered")
            return missing.isEmpty ? nil : Note("\(missing.count) of \(run.entries.count) requests lack MES-Version (SHOULD).")
        },
        ClientCheck(id: "CLIENT-002", title: "Job requests use only described inputs and parameters, valid against the descriptor",
                    spec: "§7.1, §16", scenario: "normal") { run in
            try check(!run.jobPosts.isEmpty, "the client submitted no job")
            for post in run.jobPosts {
                guard let body = post.request.body, let value = try? MESJSON.decoder.decode(JSONValue.self, from: body) else {
                    throw Failure("a job request isn't JSON")
                }
                try schemas.require(value, "base/job-request.schema.json", "the job request")
                let request = try value.decode(as: JobRequest.self)
                guard let d = run.descriptors.first(where: { $0.operation == request.operation }) else {
                    throw Failure("the client asked for \(request.operation), which the engine doesn't describe")
                }
                let names = Set(d.inputs.map(\.name))
                let extra = Set(request.inputs?.keys.map { $0 } ?? []).subtracting(names)
                try check(extra.isEmpty, "undescribed inputs: \(extra.sorted())")
                let issues = SchemaValidator().validate(.object(request.params ?? [:]), against: d.params)
                try check(issues.isEmpty, "params don't satisfy the descriptor: \(issues.prefix(2).map(\.description))")
                let declared = Set((d.extensions ?? []).map(\.name))
                let undeclared = Set(request.extensions?.keys.map { $0 } ?? []).subtracting(declared)
                try check(undeclared.isEmpty, "undeclared extensions: \(undeclared.sorted())")
            }
            return nil
        },
        ClientCheck(id: "CLIENT-003", title: "One submission per task, and following the job doesn't busy-poll", spec: "§7.3, §11", scenario: "normal") { run in
            try check(run.jobPosts.count == 1, "the client submitted \(run.jobPosts.count) jobs for one task")
            // Snapshots without a long poll: GET jobs/{id} with no positive ?wait.
            let snapshots = run.entries.filter { e in
                let parts = e.request.path.split(separator: "/")
                let waits = (e.request.query ?? "").split(separator: "&").contains { $0.hasPrefix("wait=") && $0 != "wait=0" }
                return e.request.method == "GET" && parts.count == 2 && parts[0] == "jobs" && !waits
            }
            guard let first = run.entries.first?.request.receivedAt, let last = run.entries.last?.request.receivedAt else { return nil }
            let span = max(1, last.timeIntervalSince(first))
            let rate = Double(snapshots.count) / span
            try check(rate <= 2, String(format: "%d job snapshots without ?wait in %.1f s (%.1f/s); long-poll or use events", snapshots.count, span, rate))
            return nil
        },
        ClientCheck(id: "CLIENT-004", title: "What the client collects, it confirms or releases: no job is left holding", spec: "§7.3, §13, §16",
                    scenario: "normal") { run in
            let held = run.jobsAfter.filter { $0.state == .holding }
            try check(held.isEmpty, "after the client exited, \(held.map(\.id)) still held outputs (confirm or release them)")
            return nil
        },
        ClientCheck(id: "CLIENT-005", title: "The task completes: the job's output is fetched and the client exits 0", spec: "§7", scenario: "normal") { run in
            try completed(run)
            return nil
        },
        ClientCheck(id: "CLIENT-010", title: "429 busy: waits for Retry-After, then retries and completes", spec: "§7.1, §12, §16", scenario: "busy") { run in
            try honoursRetryAfter(run, status: 429)
        },
        ClientCheck(id: "CLIENT-011", title: "503 no_capacity: waits for Retry-After, then retries and completes", spec: "§12, §16",
                    scenario: "no-capacity") { run in
            try honoursRetryAfter(run, status: 503)
        },
        ClientCheck(id: "CLIENT-020", title: "A failed job is reported as a failure; no outputs are fetched and nothing is resubmitted",
                    spec: "§7.2, §16", scenario: "failed") { run in
            try reportedFailure(run, "a failed job")
            try check(run.outputGets.isEmpty, "the client asked a failed job for outputs")
            try check(run.jobPosts.count == 1, "the client resubmitted a failed job (\(run.jobPosts.count) submissions)")
            return nil
        },
        ClientCheck(id: "CLIENT-021", title: "A job cancelled on the engine is reported, and no outputs are fetched", spec: "§7.2, §16",
                    scenario: "cancelled") { run in
            try check(run.jobsAfter.contains { $0.outcome == .cancelled }, "the scenario didn't manage to cancel the job (\(run.jobsAfter.map { $0.outcome?.rawValue ?? $0.state.rawValue }))")
            try reportedFailure(run, "a cancelled job")
            try check(run.outputGets.isEmpty, "the client asked a cancelled job for outputs")
            return nil
        },
        ClientCheck(id: "CLIENT-022", title: "An unknown error code is handled by its HTTP class: reported, and a 4xx isn't retried",
                    spec: "§12", scenario: "unknown-error") { run in
            try reportedFailure(run, "a 422 with an unknown code")
            try check(run.jobPosts.count == 1, "the client retried a 4xx \(run.jobPosts.count - 1) times")
            return nil
        },
        ClientCheck(id: "CLIENT-023", title: "Outputs that are gone (410) are reported, not retried in a loop", spec: "§7.3, §13", scenario: "gone") { run in
            try reportedFailure(run, "410 gone on its output")
            try check(run.outputGets.count <= 2, "the client asked for a gone output \(run.outputGets.count) times")
            return nil
        },
    ]

    /// The catalogue as Markdown rows.
    static var markdown: String {
        all.map { "| \($0.id) | \($0.title) | \($0.spec) | `\($0.scenario)` |" }.joined(separator: "\n")
    }
}
