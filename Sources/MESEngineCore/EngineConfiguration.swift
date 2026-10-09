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
    /// `open`: HTTP, loopback only, one local client. `paired`: TLS with a self-signed certificate, pairing, bearer
    /// tokens, and per-client job ownership (Base §3.3, §5). Paired engines usually bind "0.0.0.0".
    public var mode: AuthMode = .open
    /// Where the TLS identity and pairings persist. Never the spool, which is wiped at start.
    public var stateDirectory: URL
    /// Asked for every pairing request (Base §5: a local person approves, unless an operator policy pre-approves).
    /// The default declines everything; `EngineConfiguration.approveAll` pre-approves.
    public var pairingApproval: @Sendable (PairingPrompt) async -> Bool = { _ in false }
    /// Advertise `_mes-engine._tcp` over DNS-SD. Open mode advertises on this machine only.
    public var advertise: Bool = true

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
    /// Closes keep-alive connections idle between requests. A request in flight (a long poll, an SSE stream, an MCP
    /// call waiting `wait_s`) isn't idle.
    public var idleTimeout: Duration = .seconds(60)
    /// Closes a connection that hasn't sent a complete first request head (or finished a WebSocket upgrade, or its TLS
    /// handshake) this long after opening: slow or malformed clients can't hold connections.
    public var requestHeadTimeout: Duration = .seconds(10)
    public var heartbeat: Duration = .seconds(15)
    /// Progress events are coalesced to at most this rate (Base §11: SHOULD ≤ 10/s).
    public var minProgressInterval: Duration = .milliseconds(100)

    public static let baseVersions = ["0.1"]

    public init(id: String, name: String, implementationName: String, implementationVersion: String,
                implementationURL: String? = nil, spoolDirectory: URL) {
        self.id = id; self.name = name; self.implementationName = implementationName
        self.implementationVersion = implementationVersion; self.implementationURL = implementationURL
        self.spoolDirectory = spoolDirectory
        stateDirectory = spoolDirectory.deletingLastPathComponent()
            .appendingPathComponent(spoolDirectory.lastPathComponent + "-state", isDirectory: true)
    }

    /// An operator policy that pre-approves every pairing (for development and unattended hosts).
    public static let approveAll: @Sendable (PairingPrompt) async -> Bool = { _ in true }

    package var features: [Feature] {
        [.uploads, .sse] + (grants ? [.grants] : []) + [.previews, .websocket, .mcp] + (mode == .paired ? [.pairing] : [])
    }
}

/// What a person sees on the engine side of a pairing (Base §5 step 4): who is asking, and the code their screen
/// should show too.
public struct PairingPrompt: Sendable, Equatable {
    public let clientID: String
    public let clientName: String
    public let code: String
    package init(clientID: String, clientName: String, code: String) {
        self.clientID = clientID; self.clientName = clientName; self.code = code
    }
}
