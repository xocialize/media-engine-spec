import Foundation
import MESClientKit
import MESCore
import MESEngineCore

/// An engine in the client's own process, behind the same `EngineConnection` as engines on the network
/// (MES:DLV-3, DESK:RUN-9). Desktop registers its built-in ForgeCore this way, so local and remote processing look
/// and record the same: the same descriptors, validation, job lifecycle, events, retention and provenance. Streamed
/// outputs' chunks (Base §11 rule 3) arrive through `events` and `outputChunks` as they do over SSE, with no sockets;
/// assets and voice lists are the registry's own.
///
///     let forge = try await InProcessEngine.start(engine: ForgeCoreEngine(), configuration: config)
///     let job = try await forge.run(request)
public final class InProcessEngine: EngineConnection, Sendable {
    /// The one client of an in-process engine.
    public static let owner = "local"
    let registry: JobRegistry
    let spool: Spool

    private init(registry: JobRegistry, spool: Spool) {
        self.registry = registry
        self.spool = spool
    }

    /// Prepares the spool (wiping leftovers, Base §13 rule 3), loads the engine's descriptors and starts the
    /// retention sweeper. `configuration.mode`, ports and origins don't apply in process.
    public static func start(engine: any MediaEngine, configuration: EngineConfiguration) async throws -> InProcessEngine {
        let (spool, _) = try Spool.prepare(at: configuration.spoolDirectory)
        let registry = JobRegistry(engine: engine, config: configuration, spool: spool)
        await registry.start()
        return InProcessEngine(registry: registry, spool: spool)
    }

    /// Stops the sweeper and ends every event stream.
    public func stop() async { await registry.stop() }

    public func engineInfo() async throws -> EngineInfo { await registry.engineInfo() }

    public func operations() async throws -> OperationsList { await registry.operationsList }

    public func health() async throws -> Health { await registry.health() }

    public func upload(contentsOf file: URL, mediaType: String) async throws -> Upload {
        let id = IDs.make("upl_")
        let destination = spool.uploadFile(id)
        try FileManager.default.copyItem(at: file, to: destination)
        let (sha, bytes) = try Hashing.sha256(of: destination)
        return await registry.createUpload(owner: Self.owner, mediaType: mediaType, file: destination, bytes: bytes, sha256: sha)
    }

    public func createAsset(contentsOf file: URL, mediaType: String, ttlSeconds: Int) async throws -> Asset {
        guard ttlSeconds >= 60 else {
            throw MESClientError.engine(MESError(.invalidRequest, "ttl_s is required: at least 60 seconds.", param: "ttl_s"),
                                        status: 400, retryAfter: nil)
        }
        let id = IDs.make("ast_")
        let destination = spool.assetFile(id)
        try FileManager.default.copyItem(at: file, to: destination)
        let (sha, bytes) = try Hashing.sha256(of: destination)
        return try await engineCall {
            try await registry.createAsset(owner: Self.owner, mediaType: mediaType, file: destination, bytes: bytes, sha256: sha,
                                           ttlSeconds: ttlSeconds)
        }
    }

    public func assets() async throws -> [Asset] { await registry.listAssets(owner: Self.owner) }

    public func asset(_ id: String) async throws -> Asset { try await engineCall { try await registry.asset(id, owner: Self.owner) } }

    public func deleteAsset(_ id: String) async throws { try await engineCall { try await registry.deleteAsset(id, owner: Self.owner) } }

    public func voices(operation: String, model: String) async throws -> VoiceList {
        try await engineCall { try await registry.voices(operation: operation, model: model) }
    }

    public func submit(_ request: JobRequest, idempotencyKey: String?) async throws -> Job {
        try await engineCall { try await registry.submit(request, owner: Self.owner, clientHost: "127.0.0.1", idempotencyKey: idempotencyKey) }
    }

    public func job(_ id: String, wait: Int) async throws -> Job {
        try await engineCall { try await registry.waitForChange(id, owner: Self.owner, seconds: min(60, max(0, wait))) }
    }

    public func jobs(state: JobState?) async throws -> [Job] { await registry.list(owner: Self.owner, state: state) }

    public func release(_ id: String) async throws -> Job { try await engineCall { try await registry.release(id, owner: Self.owner) } }

    public func confirm(_ id: String) async throws -> Job { try await engineCall { try await registry.confirm(id, owner: Self.owner) } }

    public func download(job: String, output: Output, to destination: URL) async throws -> URL {
        let (file, _) = try await engineCall { try await registry.output(job, index: output.index, owner: Self.owner) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    public func events(job id: String, after seq: Int) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let events = try await engineCall { try await registry.subscribe(id, owner: Self.owner, after: seq) }
                    for await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Engine errors surface as they do over HTTP: `MESClientError.engine` with the §12 status.
    private func engineCall<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let error as MESError {
            throw MESClientError.engine(error, status: error.status, retryAfter: error.code == MESErrorCode.busy.rawValue ? 10 : nil)
        }
    }
}
