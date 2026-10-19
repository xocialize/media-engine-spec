import Foundation
import MESCore

/// The operator's view of an engine's work (Engines-PRD ENG-9): every job from every client, in the order the slot will
/// take them. A client sees only its own jobs over the wire (Base §5); this view is for the engine's own UI, in process.
public struct EngineActivity: Sendable, Equatable {
    /// Every job the engine still holds a record of: active ones first, in slot order, then finished ones, newest first
    /// (at most `finishedLimit`).
    public var jobs: [JobActivity]
    /// How many jobs run at once (the engine's heavy slots, ENG-3).
    public var concurrency: Int

    public init(jobs: [JobActivity] = [], concurrency: Int = 1) {
        self.jobs = jobs
        self.concurrency = concurrency
    }

    /// The finished jobs a snapshot keeps.
    public static let finishedLimit = 50

    /// Running now.
    public var running: [JobActivity] { jobs.filter { $0.state == .running } }
    /// Waiting for the slot, in the order they'll get it, then those still receiving or fetching inputs.
    public var upcoming: [JobActivity] { jobs.filter { $0.isUpcoming } }
    /// Done, newest first.
    public var finished: [JobActivity] { jobs.filter { $0.outcome != nil } }
}

/// One job, as the operator sees it.
public struct JobActivity: Sendable, Equatable, Identifiable {
    public var id: String
    public var operation: String
    /// The client that submitted it (`local` in open mode).
    public var client: String
    public var clientHost: String?
    /// The model the kit chose, or the client named.
    public var model: ModelRef
    public var quality: QualityTier
    public var state: JobState
    public var outcome: Outcome?
    public var progress: JobProgress?
    public var warnings: [Warning]
    public var error: String?
    /// The request's first text input (usually its prompt), shortened, so a queue row says what the job is.
    public var summary: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    /// 1-based place among the jobs waiting for the slot; nil unless waiting.
    public var queuePosition: Int?

    public init(id: String, operation: String, client: String, clientHost: String? = nil, model: ModelRef,
                quality: QualityTier, state: JobState, outcome: Outcome? = nil, progress: JobProgress? = nil,
                warnings: [Warning] = [], error: String? = nil, summary: String? = nil, createdAt: Date,
                startedAt: Date? = nil, finishedAt: Date? = nil, queuePosition: Int? = nil) {
        self.id = id; self.operation = operation; self.client = client; self.clientHost = clientHost
        self.model = model; self.quality = quality; self.state = state; self.outcome = outcome
        self.progress = progress; self.warnings = warnings; self.error = error; self.summary = summary
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.queuePosition = queuePosition
    }

    /// Not yet running and not finished: receiving, fetching inputs, or waiting for the slot.
    public var isUpcoming: Bool { outcome == nil && [.received, .fetching, .waiting].contains(state) }

    /// Time spent waiting before it ran (or so far, if it hasn't).
    public func waited(now: Date = Date()) -> TimeInterval { (startedAt ?? now).timeIntervalSince(createdAt) }

    /// Time spent running (or so far, if it still is); nil if it never ran.
    public func ran(now: Date = Date()) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    /// The request's first text input, on one line and at most `limit` characters.
    static func summary(of request: JobRequest, limit: Int = 140) -> String? {
        let preferred = ["prompt", "instruction", "text"]
        let inputs = request.inputs ?? [:]
        let names = preferred.filter { inputs[$0] != nil } + inputs.keys.sorted().filter { !preferred.contains($0) }
        for name in names {
            guard case .text(let text)? = inputs[name] else { continue }
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }
}
