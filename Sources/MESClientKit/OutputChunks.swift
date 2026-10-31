import Foundation
import MESCore

/// One piece of a streamed output (Base §11, `job.output_chunk`): raw interleaved little-endian PCM in its stream's
/// encoding, whole frames only.
public struct OutputChunk: Sendable, Equatable {
    public var job: String?
    /// The output's name, from the descriptor.
    public var output: String
    /// 0, 1, 2, … per output, with no gaps.
    public var index: Int
    /// Where the chunk starts, in seconds (informative: the exact position is the frames of the chunks before it).
    public var offsetSeconds: Double
    /// The output's last chunk, sent once the job has succeeded. It may be empty.
    public var final: Bool
    /// The samples; nil for a chunk replayed after the job's outputs were purged (§11 rule 4).
    public var samples: Data?
    /// The stream's format from the plan (§7.2), when the reader has seen it.
    public var format: StreamPlan?

    public init(job: String? = nil, output: String, index: Int, offsetSeconds: Double, final: Bool, samples: Data?,
                format: StreamPlan? = nil) {
        self.job = job; self.output = output; self.index = index; self.offsetSeconds = offsetSeconds; self.final = final
        self.samples = samples; self.format = format
    }

    /// The chunk an event carries, or nil for any other event.
    public init?(_ event: Event) {
        guard event.type == .outputChunk, let output = event.data["output"]?.stringValue,
              let index = event.data["index"]?.intValue else { return nil }
        self.init(job: event.job, output: output, index: index, offsetSeconds: event.data["offset_s"]?.numberValue ?? 0,
                  final: event.data["final"]?.boolValue ?? false,
                  samples: event.data["data"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    }

    /// Frames in this chunk, once the format is known.
    public var frames: Int? { format.map { $0.frameBytes > 0 ? (samples?.count ?? 0) / $0.frameBytes : 0 } }
}

/// A streamed output that ended without its final chunk (§11 rule 5): the job failed, was cancelled or expired while
/// it streamed, and what arrived isn't an output.
public struct StreamIncomplete: Error, Sendable, Equatable, CustomStringConvertible {
    public var output: String
    /// How many chunks arrived.
    public var chunks: Int
    public var outcome: Outcome?
    public var error: MESError?

    public var description: String {
        "The stream of \(output) ended after \(chunks) chunk\(chunks == 1 ? "" : "s") without its final one"
            + (outcome.map { " (the job \($0.rawValue)\(error.map { ": \($0.code)" } ?? ""))" } ?? "") + "."
    }
}

/// Reads a job's events into its streams' chunks (Base §11): each output's chunks in order and once (WebSocket
/// subscriptions can overlap and deliver an event twice), with the format from `job.plan`.
///
/// Use it to fold chunks into your own event loop; `EngineConnection.outputChunks(job:)` and
/// `EventChannel.outputChunks(job:)` wrap it as a sequence.
public struct ChunkReader: Sendable {
    public let job: String?
    /// Each stream's format by output, from the plan.
    public private(set) var plans: [String: StreamPlan]
    private var next: [String: Int] = [:]
    private var received: [String: Int] = [:]
    private var finished: Set<String> = []
    private let resuming: Bool

    /// - Parameters:
    ///   - job: only this job's events count (a WebSocket channel subscribed to `"*"` carries every job's).
    ///   - plans: the streams' formats when they're already known (a snapshot's `plan.streams`).
    ///   - resuming: events start after some `seq`, so each output's first chunk seen may not be index 0.
    public init(job: String? = nil, plans: [StreamPlan] = [], resuming: Bool = false) {
        self.job = job
        self.plans = Dictionary(plans.map { ($0.output, $0) }, uniquingKeysWith: { a, _ in a })
        self.resuming = resuming
    }

    /// Whether `output` has had its final chunk.
    public func isFinished(_ output: String) -> Bool { finished.contains(output) }

    /// Whether every planned stream has had its final chunk (false while no plan has arrived).
    public var isComplete: Bool { !plans.isEmpty && plans.keys.allSatisfy(finished.contains) }

    /// One event in: the chunk it carries when that's the next of its output, else nil (another job's event, another
    /// kind of event, or a duplicate). Throws `StreamIncomplete` when the job ends, or holds its outputs, with a planned
    /// stream unfinished, and `MESClientError.unexpected` when a chunk is missing.
    public mutating func read(_ event: Event) throws -> OutputChunk? {
        if let job, let other = event.job, other != job { return nil }
        switch event.type {
        case .plan:
            for plan in (try? event.data["streams"]?.decode(as: [StreamPlan].self)) ?? [] { plans[plan.output] = plan }
            return nil
        case .outputChunk:
            guard var chunk = OutputChunk(event), !finished.contains(chunk.output) else { return nil }
            let expected = next[chunk.output] ?? (resuming ? chunk.index : 0)
            if chunk.index < expected { return nil }
            guard chunk.index == expected else {
                throw MESClientError.unexpected("Chunk \(expected) of \(chunk.output) is missing (got \(chunk.index)).")
            }
            next[chunk.output] = expected + 1
            received[chunk.output, default: 0] += 1
            if chunk.final { finished.insert(chunk.output) }
            chunk.format = plans[chunk.output]
            return chunk
        case .outputReady:
            try checkFinished(outcome: nil, error: nil)
            return nil
        case .state:
            if let outcome = event.data["outcome"]?.stringValue.flatMap(Outcome.init(rawValue:)), outcome != .succeeded {
                try checkFinished(outcome: outcome, error: nil)
            }
            return nil
        case .ended:
            try checkFinished(outcome: event.data["outcome"]?.stringValue.flatMap(Outcome.init(rawValue:)),
                              error: try? event.data["error"]?.decode(as: MESError.self))
            return nil
        default:
            return nil
        }
    }

    private func checkFinished(outcome: Outcome?, error: MESError?) throws {
        let open = Set(plans.keys).union(received.keys).subtracting(finished)
        guard let output = open.sorted().first else { return }
        throw StreamIncomplete(output: output, chunks: received[output] ?? 0, outcome: outcome, error: error)
    }
}

extension ChunkReader {
    /// The chunks a sequence of events carries, finishing after `output`'s final chunk (with `output` nil, after
    /// every planned stream's), or when the events end.
    static func chunks(_ events: AsyncThrowingStream<Event, any Error>, output: String?,
                       reader: ChunkReader) -> AsyncThrowingStream<OutputChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var reader = reader
                do {
                    for try await event in events {
                        guard let chunk = try reader.read(event) else {
                            if output == nil, reader.isComplete { break }
                            continue
                        }
                        if output == nil || chunk.output == output { continuation.yield(chunk) }
                        if let output, reader.isFinished(output) { break }
                        if output == nil, reader.isComplete { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension EngineConnection {
    /// A job's streamed output as it arrives (§11), over this connection's events: SSE over HTTP, the engine's own
    /// event stream in process. With `output` nil, every stream's chunks, interleaved in event order.
    ///
    ///     for try await chunk in engine.outputChunks(job: job.id, output: "audio") { player.enqueue(chunk.samples!) }
    ///
    /// Throws `StreamIncomplete` when the job fails or is cancelled before the final chunk.
    public func outputChunks(job: String, output: String? = nil, after seq: Int = 0) -> AsyncThrowingStream<OutputChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Resuming past the plan event: the snapshot has the formats.
                    let plans = seq > 0 ? (try await self.job(job, wait: 0)).plan?.streams ?? [] : []
                    let chunks = ChunkReader.chunks(events(job: job, after: seq), output: output,
                                                    reader: ChunkReader(job: job, plans: plans, resuming: seq > 0))
                    for try await chunk in chunks { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Submits a request that streams (its `stream`, §7.1), passes each chunk as it arrives, and returns the final
    /// snapshot as `run` does. A job that fails or is cancelled while streaming returns normally with its `outcome`;
    /// the chunks passed so far are then incomplete (§11 rule 5).
    public func runStreaming(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString,
                             onChunk: @Sendable (OutputChunk) async throws -> Void,
                             onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        let submitted = try await submit(request, idempotencyKey: idempotencyKey)
        return try await followStreaming(submitted, onChunk: onChunk, onEvent: onEvent)
    }

    /// Follows a submitted job's events, passing its chunks, until it holds its outputs or ends.
    public func followStreaming(_ job: Job, onChunk: @Sendable (OutputChunk) async throws -> Void,
                                onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        var reader = ChunkReader(job: job.id, plans: job.plan?.streams ?? [])
        do {
            for try await event in events(job: job.id, after: 0) {
                await onEvent(event)
                if let chunk = try reader.read(event) { try await onChunk(chunk) }
                if event.type == .outputReady || event.type == .ended { break }
            }
        } catch is StreamIncomplete {}
        return try await self.job(job.id, wait: 0)
    }
}

extension EventChannel {
    /// `job`'s streamed output as this channel carries it (§11 rule 3). Subscribe to the job, or `"*"`, first. This
    /// reads `messages`, so use it on a channel opened for the job; a client that reads the channel itself feeds a
    /// `ChunkReader` from its own loop instead.
    public func outputChunks(job: String, output: String? = nil) -> AsyncThrowingStream<OutputChunk, any Error> {
        let (events, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
        let pump = Task {
            do {
                for try await message in messages {
                    guard case .event(let event) = message, event.job == job else { continue }
                    continuation.yield(event)
                    if event.type == .ended { break }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return ChunkReader.chunks(events, output: output, reader: ChunkReader(job: job))
    }
}

/// Writes a stream's chunks to a WAV file as they arrive: the format Base §10.1 gives the finished output
/// (`pcm_s16le` as 16-bit integer, `pcm_f32le` as 32-bit float), so the file's samples equal the engine's output's.
/// The header's sizes are written by `finish()`; until then, players that read to the end of the file can follow it.
public struct WAVStreamWriter: Sendable {
    public let url: URL
    public let format: StreamPlan
    public private(set) var bytes = 0
    private let handle: FileHandle

    public init(url: URL, format: StreamPlan) throws {
        self.url = url
        self.format = format
        FileManager.default.createFile(atPath: url.path, contents: WAVFile(stream: format, pcm: Data()).data)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public mutating func append(_ samples: Data) throws {
        try handle.write(contentsOf: samples)
        bytes += samples.count
    }

    /// Writes the header's sizes and closes the file.
    public func finish() throws -> URL {
        func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: u32(36 + bytes))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: u32(bytes))
        try handle.close()
        return url
    }
}
