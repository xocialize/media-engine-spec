import Foundation
#if canImport(CryptoKit)
import CryptoKit

/// The pairing code (Base §5): both sides compute it from both nonces and both key fingerprints, and a person
/// compares the two 6-digit codes. A man in the middle changes a fingerprint, and therefore the code.
public enum PairingCode {
    /// `uint32_be(HMAC-SHA256(key: clientNonce ‖ engineNonce, msg: "MES-SAS-1" ‖ FE ‖ FC)[0..4]) mod 1_000_000`.
    /// Nonces are the raw bytes (decoded from base64url); fingerprints are the raw 32-byte SHA-256 digests.
    public static func code(clientNonce: Data, engineNonce: Data, engineFingerprint: Data, clientFingerprint: Data) -> String {
        let key = SymmetricKey(data: clientNonce + engineNonce)
        let message = Data("MES-SAS-1".utf8) + engineFingerprint + clientFingerprint
        let mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        let value = UInt32(mac[0]) << 24 | UInt32(mac[1]) << 16 | UInt32(mac[2]) << 8 | UInt32(mac[3])
        return String(format: "%06u", value % 1_000_000)
    }

    /// SHA-256 of DER bytes (a certificate, or a public key's SPKI).
    public static func fingerprint(_ der: Data) -> Data { Data(SHA256.hash(data: der)) }

    /// Lowercase hex, as `tls.fingerprint_sha256` carries it.
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
#endif

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
