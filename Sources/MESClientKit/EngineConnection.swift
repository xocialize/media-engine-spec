import Foundation
import MESCore
import UniformTypeIdentifiers

/// One engine, as a client sees it: the Base 0.1 operations, independent of how they travel. `HTTPEngineConnection`
/// speaks HTTP (open or paired mode); `MESInProcess.InProcessEngine` calls an engine in the same process (Desktop's
/// built-in ForgeCore, DESK:RUN-9). Code written against this protocol works with either.
public protocol EngineConnection: Sendable {
    /// `GET {path}/engine` (§4).
    func engineInfo() async throws -> EngineInfo
    /// `GET {path}/operations` (§6). HTTP connections revalidate with the ETag.
    func operations() async throws -> OperationsList
    /// `GET {path}/health` (§14).
    func health() async throws -> Health
    /// `POST {path}/uploads` (§8): one file's bytes, verified with `Content-Digest`.
    func upload(contentsOf file: URL, mediaType: String) async throws -> Upload
    /// `POST {path}/jobs` (§7.1). Pass an idempotency key to make retries safe.
    func submit(_ request: JobRequest, idempotencyKey: String?) async throws -> Job
    /// `GET {path}/jobs/{id}`, long-polling up to `wait` seconds (≤ 60) for a state change (§7.3).
    func job(_ id: String, wait: Int) async throws -> Job
    /// `GET {path}/jobs`: the caller's own jobs.
    func jobs(state: JobState?) async throws -> [Job]
    /// `DELETE {path}/jobs/{id}`: cancels a job, or discards a held job's outputs. Idempotent.
    func release(_ id: String) async throws -> Job
    /// `POST {path}/jobs/{id}/confirm`: the client has its outputs; the engine purges them.
    func confirm(_ id: String) async throws -> Job
    /// `GET {path}/jobs/{id}/outputs/{index}` into `destination`, checked against the output's SHA-256.
    func download(job: String, output: Output, to destination: URL) async throws -> URL
    /// The job's events after `seq` (§11), finishing after `job.ended`. HTTP connections use SSE and resume with
    /// `Last-Event-ID` when the connection drops.
    func events(job: String, after seq: Int) -> AsyncThrowingStream<Event, any Error>

    // Added with Base 0.1's v0.7.0 features. Each has a default that answers as an engine without the feature does
    // (404 `not_found`), so connections written before them still compile.

    /// `POST {path}/assets?ttl_s=` (§8.1, `assets` feature): one file's bytes kept for `ttlSeconds` (at least 60; the
    /// engine grants at most `limits.max_asset_ttl_s`), verified with `Content-Digest`.
    func createAsset(contentsOf file: URL, mediaType: String, ttlSeconds: Int) async throws -> Asset
    /// `GET {path}/assets`: the caller's own assets.
    func assets() async throws -> [Asset]
    /// `GET {path}/assets/{id}`.
    func asset(_ id: String) async throws -> Asset
    /// `DELETE {path}/assets/{id}`; 404 `not_found` for one the caller doesn't have.
    func deleteAsset(_ id: String) async throws
    /// `GET {path}/operations/{operation}/models/{model}/voices` (§6.5), for an offer whose `supports.voices` is above
    /// 0. HTTP connections revalidate with the ETag.
    func voices(operation: String, model: String) async throws -> VoiceList
    /// A voice's `sample` (§6.5), fetched with this connection's authorization.
    func sample(of voice: Voice) async throws -> Data
}

extension EngineConnection {
    public func createAsset(contentsOf file: URL, mediaType: String, ttlSeconds: Int) async throws -> Asset {
        throw MESClientError.missing("assets")
    }
    public func assets() async throws -> [Asset] { throw MESClientError.missing("assets") }
    public func asset(_ id: String) async throws -> Asset { throw MESClientError.missing("assets") }
    public func deleteAsset(_ id: String) async throws { throw MESClientError.missing("assets") }
    public func voices(operation: String, model: String) async throws -> VoiceList { throw MESClientError.missing("voice lists") }
    public func sample(of voice: Voice) async throws -> Data { throw MESClientError.missing("voice samples") }
}

/// What can go wrong talking to an engine.
public enum MESClientError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The engine answered with a §12 error body. `retryAfter` is from `Retry-After`, in seconds.
    case engine(MESError, status: Int, retryAfter: Int?)
    /// A non-success status without a §12 body.
    case http(status: Int, body: String)
    /// The engine's certificate isn't the pinned one (paired mode), or no certificate was presented.
    case untrustedEngine(expected: String?, presented: String?)
    /// A downloaded output didn't match its SHA-256.
    case checksumMismatch(expected: String, actual: String)
    /// The engine answered something this client can't read.
    case unexpected(String)

    /// What a connection without a feature answers: the engine's 404 `not_found`.
    static func missing(_ feature: String) -> MESClientError {
        .engine(MESError(.notFound, "This connection doesn't support \(feature)."), status: 404, retryAfter: nil)
    }

    /// The §12 code, when there is one. Clients treat unknown codes by their HTTP class (§12).
    public var code: String? { if case .engine(let e, _, _) = self { e.code } else { nil } }

    public var description: String {
        switch self {
        case .engine(let e, let status, _): "\(status) \(e.code): \(e.message)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(200))"
        case .untrustedEngine(let expected, let presented):
            "The engine presented certificate \(presented ?? "none"), not the pinned \(expected ?? "one")."
        case .checksumMismatch(let expected, let actual): "Checksum mismatch: expected \(expected), got \(actual)."
        case .unexpected(let message): message
        }
    }
}

extension EngineConnection {
    /// Submits a job and follows its events until it holds its outputs or ends, then returns the final snapshot.
    /// A job that fails returns normally with `outcome == .failed` and its `error`.
    public func run(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString,
                    onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        let submitted = try await submit(request, idempotencyKey: idempotencyKey)
        return try await follow(submitted, onEvent: onEvent)
    }

    /// Follows a submitted job's events until it holds its outputs or ends, then returns the final snapshot.
    public func follow(_ job: Job, onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        if job.state == .holding || job.state == .purged { return job }
        for try await event in events(job: job.id, after: 0) {
            await onEvent(event)
            if event.type == .outputReady || event.type == .ended { break }
        }
        return try await self.job(job.id, wait: 0)
    }

    /// A media input from a file: inline when it fits `inlineLimit` (the engine's `limits.max_inline_bytes`),
    /// otherwise uploaded (§8). The media type is inferred from the extension when not given.
    public func input(contentsOf file: URL, mediaType: String? = nil, inlineLimit: Int) async throws -> InputValue {
        let type = mediaType ?? MediaType.infer(file)
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if size <= inlineLimit { return .inline(mediaType: type, data: try Data(contentsOf: file)) }
        return .upload(try await upload(contentsOf: file, mediaType: type).uploadID)
    }

    /// Creates an asset from a file (§8.1), inferring its media type from the extension when not given.
    public func createAsset(contentsOf file: URL, mediaType: String? = nil, ttl: Duration) async throws -> Asset {
        try await createAsset(contentsOf: file, mediaType: mediaType ?? MediaType.infer(file),
                              ttlSeconds: max(60, Int(ttl.components.seconds)))
    }

    /// Downloads every output of a held job into `directory`, named `<job>-<index>.<ext>`.
    public func downloadAll(_ job: Job, to directory: URL) async throws -> [URL] {
        guard let outputs = job.result?.outputs else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        for output in outputs {
            let name = "\(job.id)-\(output.index).\(MediaType.fileExtension(output.mediaType))"
            files.append(try await download(job: job.id, output: output, to: directory.appendingPathComponent(name)))
        }
        return files
    }
}

/// Media types for files.
public enum MediaType {
    /// The media type for a file's extension, spelled as the profiles list them (Audio §1.1: `audio/wav`, not the
    /// system's `audio/vnd.wave`; `audio/mp4`, not `audio/x-m4a`).
    public static func infer(_ file: URL) -> String {
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return profileSpellings[type] ?? type
    }

    static let profileSpellings = ["audio/vnd.wave": "audio/wav", "audio/x-wav": "audio/wav", "audio/wave": "audio/wav",
                                   "audio/x-m4a": "audio/mp4"]

    public static func fileExtension(_ mediaType: String) -> String {
        UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "bin"
    }
}
