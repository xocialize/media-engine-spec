import Foundation
import MESCore

/// The files a client keeps on one engine as assets (Base §8.1), by content: a reference voice sent once and named
/// by every job that speaks with it.
///
///     let library = AssetLibrary(engine: engine)
///     let voice = try await library.input(for: clip)                      // {"asset": "ast_…"}
///     let job = try await library.run(JobRequest(operation: "audio.speak", inputs: ["voice_ref": .one(voice), …]))
///
/// An engine may drop its assets when it restarts (§8.1). A job that answers 422 `input_invalid` for an asset the
/// library holds gets it created again from its file, and is submitted once more with the new id.
public actor AssetLibrary {
    public let engine: any EngineConnection
    /// The lifetime asked for each new asset; the engine grants at most its `limits.max_asset_ttl_s`.
    public let ttlSeconds: Int
    /// Re-create an asset this many seconds before it expires rather than name one about to go.
    public let renewMargin: TimeInterval

    struct Entry: Sendable {
        var asset: Asset
        var file: URL
        var mediaType: String
    }

    /// By SHA-256 of the file's bytes.
    private var entries: [String: Entry] = [:]

    public init(engine: any EngineConnection, ttlSeconds: Int = 86_400, renewMargin: TimeInterval = 300) {
        self.engine = engine
        self.ttlSeconds = max(60, ttlSeconds)
        self.renewMargin = renewMargin
    }

    /// The assets this library holds.
    public var held: [Asset] { entries.values.map(\.asset).sorted { $0.createdAt < $1.createdAt } }

    /// The asset holding `file`'s bytes: the one this library made for the same bytes while it lives, else a new one.
    public func asset(for file: URL, mediaType: String? = nil) async throws -> Asset {
        let sha = try Self.sha256(of: file)
        if let entry = entries[sha], entry.asset.expiresAt.timeIntervalSinceNow > renewMargin { return entry.asset }
        let type = mediaType ?? MediaType.infer(file)
        let asset = try await engine.createAsset(contentsOf: file, mediaType: type, ttlSeconds: ttlSeconds)
        entries[sha] = Entry(asset: asset, file: file, mediaType: type)
        return asset
    }

    /// `file` as a job input: `{"asset": "<id>"}`.
    public func input(for file: URL, mediaType: String? = nil) async throws -> InputValue {
        .asset(try await asset(for: file, mediaType: mediaType).assetID)
    }

    /// Deletes the asset made for `file`'s bytes, if any. One the engine already dropped is forgotten all the same.
    public func remove(_ file: URL) async throws {
        let sha = try Self.sha256(of: file)
        guard let entry = entries.removeValue(forKey: sha) else { return }
        try await deleteIfThere(entry.asset.assetID)
    }

    /// Deletes every asset this library holds.
    public func removeAll() async throws {
        let all = entries.values
        entries = [:]
        for entry in all { try await deleteIfThere(entry.asset.assetID) }
    }

    /// Submits a job. On 422 `input_invalid` naming an input that holds this library's assets (or naming none), those
    /// assets are created again from their files and the job is submitted once more.
    public func submit(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString) async throws -> Job {
        do {
            return try await engine.submit(request, idempotencyKey: idempotencyKey)
        } catch let error as MESClientError {
            guard case .engine(let body, 422, _) = error, body.code == MESErrorCode.inputInvalid.rawValue,
                  let retried = try await recreated(request, param: body.param) else { throw error }
            return try await engine.submit(retried, idempotencyKey: idempotencyKey)
        }
    }

    /// `submit`, then follows the job as `EngineConnection.run` does.
    public func run(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString,
                    onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        try await engine.follow(try await submit(request, idempotencyKey: idempotencyKey), onEvent: onEvent)
    }

    /// `submit`, then follows the job's chunks as `EngineConnection.runStreaming` does.
    public func runStreaming(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString,
                             onChunk: @Sendable (OutputChunk) async throws -> Void,
                             onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> Job {
        try await engine.followStreaming(try await submit(request, idempotencyKey: idempotencyKey), onChunk: onChunk, onEvent: onEvent)
    }

    /// The request with the held assets in `param` (every input, without one) created again; nil when it names none.
    private func recreated(_ request: JobRequest, param: String?) async throws -> JobRequest? {
        guard var inputs = request.inputs else { return nil }
        var replaced = false
        for name in inputs.keys.sorted() where param == nil || param == name {
            guard let input = inputs[name] else { continue }
            var values: [InputValue] = []
            for value in Self.values(input) {
                guard case .asset(let id) = value, let sha = entries.first(where: { $0.value.asset.assetID == id })?.key,
                      let entry = entries[sha] else { values.append(value); continue }
                let asset = try await engine.createAsset(contentsOf: entry.file, mediaType: entry.mediaType, ttlSeconds: ttlSeconds)
                entries[sha]?.asset = asset
                values.append(.asset(asset.assetID))
                replaced = true
            }
            if case .many = input { inputs[name] = .many(values) } else if let first = values.first { inputs[name] = .one(first) }
        }
        guard replaced else { return nil }
        var retried = request
        retried.inputs = inputs
        return retried
    }

    static func values(_ input: RequestInput) -> [InputValue] {
        switch input {
        case .one(let v): [v]
        case .many(let vs): vs
        case .text: []
        }
    }

    /// Deletes an asset; one the engine no longer has is gone all the same.
    private func deleteIfThere(_ id: String) async throws {
        do { try await engine.deleteAsset(id) } catch let error as MESClientError where error.code == MESErrorCode.notFound.rawValue {}
    }

    static func sha256(of file: URL) throws -> String {
        try HTTPEngineConnection.sha256(of: file).map { String(format: "%02x", $0) }.joined()
    }
}
