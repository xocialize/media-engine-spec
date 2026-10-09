import Crypto
import Foundation
import MESCore
import MESEngineCore

/// A client the engine trusts (persisted). Only the token's hash is stored.
public struct PairedClient: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientName: String
    public var clientKeyFingerprint: String
    public var tokenSHA256: String
    public var pairedAt: Date
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", clientName = "client_name", clientKeyFingerprint = "client_key_fingerprint"
        case tokenSHA256 = "token_sha256", pairedAt = "paired_at"
    }
}

enum PairingOutcome: Sendable, Equatable {
    case awaiting
    case approved(PairingApproved)
}

/// Pairing requests in flight, and the clients already paired (Base §5).
actor PairingRegistry {
    struct Pending {
        var request: PairingRequest
        var clientKeyFingerprint: String
        var code: String
        var expiresAt: Date
        var state: State
        var waiters: [CheckedContinuation<Void, Never>] = []
        enum State { case awaiting, approved(String), rejected }
    }

    private let store: URL
    private let identity: EngineIdentity
    private let approve: @Sendable (PairingPrompt) async -> Bool
    private var paired: [String: PairedClient] = [:]                      // by client id
    private var pending: [String: Pending] = [:]
    static let lifetime: TimeInterval = 300                               // pairing requests expire in 5 minutes

    init(stateDirectory: URL, identity: EngineIdentity, approve: @escaping @Sendable (PairingPrompt) async -> Bool) {
        store = stateDirectory.appendingPathComponent("pairings.json")
        self.identity = identity
        self.approve = approve
        if let data = try? Data(contentsOf: store), let list = try? MESJSON.decoder.decode([PairedClient].self, from: data) {
            paired = Dictionary(list.map { ($0.clientID, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    func clients() -> [PairedClient] { paired.values.sorted { $0.pairedAt < $1.pairedAt } }

    /// The client a bearer token belongs to, if any.
    func client(forToken token: String) -> String? {
        let hash = Self.hash(token)
        return paired.values.first { $0.tokenSHA256 == hash }?.clientID
    }

    func create(_ request: PairingRequest) throws -> PairingCreated {
        guard let clientKey = Base64URL.decode(request.clientKey), clientKey.count >= 64,
              (try? P256.Signing.PublicKey(derRepresentation: clientKey)) != nil else {
            throw MESError(.invalidRequest, "client_key must be a P-256 public key (SPKI DER, base64url).", param: "client_key")
        }
        guard let clientNonce = Base64URL.decode(request.clientNonce), clientNonce.count >= 16 else {
            throw MESError(.invalidRequest, "client_nonce must be at least 16 random bytes (base64url).", param: "client_nonce")
        }
        let engineNonce = Self.randomBytes(32)
        let clientFingerprint = PairingCode.fingerprint(clientKey)
        let code = PairingCode.code(clientNonce: clientNonce, engineNonce: engineNonce,
                                    engineFingerprint: identity.fingerprint, clientFingerprint: clientFingerprint)
        let id = IDs.make("pair_", length: 16)
        let expires = Date().addingTimeInterval(Self.lifetime)
        pending[id] = Pending(request: request, clientKeyFingerprint: PairingCode.hex(clientFingerprint), code: code,
                              expiresAt: expires, state: .awaiting)
        let prompt = PairingPrompt(clientID: request.clientID, clientName: request.clientName, code: code)
        let approve = self.approve
        Task { [weak self] in
            let approved = await approve(prompt)
            await self?.decide(id, approved: approved)
        }
        return PairingCreated(pairingID: id, engineNonce: Base64URL.encode(engineNonce), expiresAt: expires)
    }

    private func decide(_ id: String, approved: Bool) {
        guard var p = pending[id], case .awaiting = p.state, p.expiresAt > Date() else { return }
        if approved {
            let token = "mes_tok_" + Base64URL.encode(Self.randomBytes(32))
            p.state = .approved(token)
            paired[p.request.clientID] = PairedClient(clientID: p.request.clientID, clientName: p.request.clientName,
                                                      clientKeyFingerprint: p.clientKeyFingerprint,
                                                      tokenSHA256: Self.hash(token), pairedAt: Date())
            persist()
        } else {
            p.state = .rejected
        }
        let waiters = p.waiters
        p.waiters = []
        pending[id] = p
        for w in waiters { w.resume() }
    }

    /// `POST {path}/pairings/{id}/confirm`, optionally waiting up to `seconds` for the engine-side decision.
    func confirm(_ id: String, wait seconds: Int) async throws -> PairingOutcome {
        guard let p = pending[id] else { throw MESError(.notFound, "No pairing \(id).") }
        guard p.expiresAt > Date() else { pending[id] = nil; throw MESError(.gone, "Pairing \(id) expired.") }
        if case .awaiting = p.state, seconds > 0 {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.waitForDecision(id) }
                group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
                await group.next()
                group.cancelAll()
            }
        }
        guard let current = pending[id] else { throw MESError(.gone, "Pairing \(id) expired.") }
        switch current.state {
        case .awaiting: return .awaiting
        case .rejected:
            pending[id] = nil
            throw MESError(.pairingRejected, "The engine's operator declined the pairing.")
        case .approved(let token):
            pending[id] = nil                                              // the token is handed out once
            return .approved(PairingApproved(token: token, clientID: current.request.clientID))
        }
    }

    private func waitForDecision(_ id: String) async {
        guard let p = pending[id], case .awaiting = p.state else { return }
        await withCheckedContinuation { continuation in pending[id]?.waiters.append(continuation) }
    }

    /// `DELETE {path}/pairings/self`, or an operator revoking a client.
    func unpair(_ clientID: String) {
        paired[clientID] = nil
        persist()
    }

    private func persist() {
        guard let data = try? MESJSON.encoder.encode(clients()) else { return }
        try? data.write(to: store, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
    }

    /// Cryptographically random bytes (SystemRandomNumberGenerator is a CSPRNG on Apple platforms).
    static func randomBytes(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    static func hash(_ token: String) -> String { PairingCode.hex(Data(SHA256.hash(data: Data(token.utf8)))) }
}
