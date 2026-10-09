import CryptoKit
import Foundation
import MESCore

/// The client's identity for pairing (Base §5): an id, a name people recognise, and a P-256 key. Apps persist it
/// (`rawKey` in the keychain) and reuse it for every engine.
public struct ClientIdentity: Sendable {
    public let id: String
    public let name: String
    public let key: P256.Signing.PrivateKey

    public init(id: String, name: String, key: P256.Signing.PrivateKey) {
        self.id = id; self.name = name; self.key = key
    }

    /// A new identity with a fresh key and a random `cli_` id.
    public static func generate(name: String) -> ClientIdentity {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var g = SystemRandomNumberGenerator()
        let id = "cli_" + String((0..<16).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &g)] })
        return ClientIdentity(id: id, name: name, key: P256.Signing.PrivateKey())
    }

    /// The key's raw representation, for storage.
    public var rawKey: Data { key.rawRepresentation }

    /// `FC`: the SHA-256 of the public key (SPKI, DER).
    public var fingerprint: Data { PairingCode.fingerprint(key.publicKey.derRepresentation) }
}

/// What a client keeps after pairing: where the engine is, its pinned certificate and the token.
public struct PairedEngine: Codable, Sendable, Equatable {
    public var engineID: String
    public var engineName: String
    public var baseURL: URL
    /// `FE`, hex: the SHA-256 of the engine's certificate, pinned for every later connection.
    public var fingerprintSHA256: String
    public var token: String
    public var clientID: String

    enum CodingKeys: String, CodingKey {
        case engineID = "engine_id", engineName = "engine_name", baseURL = "base_url"
        case fingerprintSHA256 = "fingerprint_sha256", token, clientID = "client_id"
    }

    static func data(hex: String) -> Data? {
        var bytes = [UInt8]()
        var chars = hex.makeIterator()
        while let a = chars.next(), let b = chars.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes.count == 32 ? Data(bytes) : nil
    }
}

/// A pairing in progress: show `code` to the user (the engine's operator sees the same one), then `confirm`.
///
///     let pairing = try await Pairing.begin(baseURL: url, identity: me)
///     print("Check the engine shows \(pairing.code)")
///     if case .approved(let engine) = try await pairing.confirm(wait: 60) { save(engine) }
public struct Pairing: Sendable {
    public enum Outcome: Sendable, Equatable {
        case approved(PairedEngine)
        /// The engine's operator hasn't answered yet; call `confirm` again.
        case awaitingApproval
    }

    public let pairingID: String
    /// The 6-digit code both screens show.
    public let code: String
    public let engine: EngineInfo
    public let expiresAt: Date
    /// `FE`: the certificate the engine presented during pairing.
    public let engineFingerprint: Data
    let baseURL: URL
    let clientID: String

    /// Steps 1–4 of Base §5: trusts the engine's certificate provisionally, sends the client's key and nonce, and
    /// computes the code. Fails if the certificate served doesn't match the one the engine advertises.
    public static func begin(baseURL: URL, identity: ClientIdentity) async throws -> Pairing {
        let connection = HTTPEngineConnection(baseURL: baseURL, trustOnFirstUse: true)
        let info = try await connection.engineInfo()
        guard let presented = connection.presentedFingerprint else {
            throw MESClientError.unexpected("Pairing needs TLS; \(baseURL) didn't present a certificate.")
        }
        guard info.tls?.fingerprintSHA256 == PairingCode.hex(presented) else {
            throw MESClientError.untrustedEngine(expected: info.tls?.fingerprintSHA256, presented: PairingCode.hex(presented))
        }
        var nonce = [UInt8](repeating: 0, count: 32)
        var g = SystemRandomNumberGenerator()
        for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255, using: &g) }
        let request = PairingRequest(clientID: identity.id, clientName: identity.name,
                                     clientKey: Base64URL.encode(identity.key.publicKey.derRepresentation),
                                     clientNonce: Base64URL.encode(Data(nonce)))
        let pinned = HTTPEngineConnection(baseURL: baseURL, pinnedFingerprint: presented)
        let created = try pinned.decode(PairingCreated.self, try await pinned.send(
            "POST", "pairings", headers: ["Content-Type": "application/json"], body: try MESJSON.encoder.encode(request),
            accept: [201]))
        guard let engineNonce = Base64URL.decode(created.engineNonce) else {
            throw MESClientError.unexpected("The engine's nonce isn't base64url.")
        }
        let code = PairingCode.code(clientNonce: Data(nonce), engineNonce: engineNonce, engineFingerprint: presented,
                                    clientFingerprint: identity.fingerprint)
        return Pairing(pairingID: created.pairingID, code: code, engine: info, expiresAt: created.expiresAt,
                       engineFingerprint: presented, baseURL: baseURL, clientID: identity.id)
    }

    /// Step 5: waits up to `wait` seconds for the engine's operator. Throws `pairing_rejected` (403) if declined and
    /// `gone` (410) if the pairing expired.
    public func confirm(wait: Int = 60) async throws -> Outcome {
        let connection = HTTPEngineConnection(baseURL: baseURL, pinnedFingerprint: engineFingerprint)
        let (data, response) = try await connection.send(
            "POST", "pairings/\(pairingID)/confirm", headers: ["Content-Type": "application/json", "Prefer": "wait=\(wait)"],
            body: Data("{}".utf8), accept: [200, 202], timeout: TimeInterval(wait + 30))
        guard response.statusCode == 200 else { return .awaitingApproval }
        let approved = try connection.decode(PairingApproved.self, (data, response))
        return .approved(PairedEngine(engineID: engine.id, engineName: engine.name, baseURL: baseURL,
                                      fingerprintSHA256: PairingCode.hex(engineFingerprint), token: approved.token,
                                      clientID: approved.clientID))
    }

    /// Step 7: removes this client's pairing from the engine.
    public static func unpair(_ engine: PairedEngine) async throws {
        let connection = HTTPEngineConnection(paired: engine)
        _ = try await connection.send("DELETE", "pairings/self", accept: [204])
    }
}
