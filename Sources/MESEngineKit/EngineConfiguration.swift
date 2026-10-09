import Foundation
import MESCore

/// How an engine is served. Defaults follow Base 0.1's SHOULDs.
public struct EngineConfiguration: Sendable {
    public var id: String
    public var name: String
    public var implementationName: String
    public var implementationVersion: String
    public var implementationURL: String?

    public var host: String = "127.0.0.1"
    /// 0 picks a free port (reported by `MESEngineServer.onRunning`).
    public var port: Int = 0
    public var basePath: String = "/mes/v0"
    /// R0b.1 serves `open` mode (loopback only). `paired` mode arrives with TLS and pairing (R0b.2).
    public var mode: AuthMode = .open

    /// The engine's private spool. Wiped at start (Base §13 rule 3).
    public var spoolDirectory: URL
    public var outputsTTLSeconds: Int = 3600
    public var jobRecordTTLSeconds: Int = 86_400
    public var uploadTTLSeconds: Int = 3600

    public var maxUploadBytes: Int = 256 << 20
    public var maxInlineBytes: Int = 8 << 20
    public var maxJSONBodyBytes: Int = 64 << 20
    public var maxQueuedJobsPerClient: Int = 32
    /// Jobs run at once. A heavy engine runs one.
    public var concurrency: Int = 1

    /// Browser origins allowed to call the engine. Empty refuses every request that carries an `Origin`.
    public var allowedOrigins: Set<String> = []
    public var grants: Bool = true
    public var sweepInterval: Duration = .seconds(5)
    public var heartbeat: Duration = .seconds(15)
    /// Progress events are coalesced to at most this rate (Base §11: SHOULD ≤ 10/s).
    public var minProgressInterval: Duration = .milliseconds(100)

    public static let baseVersions = ["0.1"]

    public init(id: String, name: String, implementationName: String, implementationVersion: String,
                implementationURL: String? = nil, spoolDirectory: URL) {
        self.id = id; self.name = name; self.implementationName = implementationName
        self.implementationVersion = implementationVersion; self.implementationURL = implementationURL
        self.spoolDirectory = spoolDirectory
    }

    var features: [Feature] { [.uploads, .sse] + (grants ? [.grants] : []) + [.previews] }
}
