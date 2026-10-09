import Crypto
import Foundation
import MESCore
import NIOSSL
import SwiftASN1
import X509

/// The engine's TLS identity for `paired` mode (Base §3.3, §5): a self-signed P-256 certificate that clients pin at
/// pairing. Kept in the state directory (never the spool, which is wiped), so pairings survive restarts.
struct EngineIdentity: Sendable {
    let certificateDER: [UInt8]
    let privateKeyPEM: String

    var fingerprint: Data { Data(SHA256.hash(data: certificateDER)) }
    var fingerprintHex: String { PairingCode.hex(fingerprint) }

    static func loadOrCreate(in directory: URL, commonName: String) throws -> EngineIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent("identity-cert.der")
        let keyURL = directory.appendingPathComponent("identity-key.pem")
        if let der = try? Data(contentsOf: certURL), let pem = try? String(contentsOf: keyURL, encoding: .utf8) {
            return EngineIdentity(certificateDER: Array(der), privateKeyPEM: pem)
        }
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName(commonName) }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(20 * 365 * 86_400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName("localhost")])
            },
            issuerPrivateKey: .init(key))
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = serializer.serializedBytes
        let pem = key.pemRepresentation
        try Data(der).write(to: certURL)
        try pem.write(to: keyURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return EngineIdentity(certificateDER: der, privateKeyPEM: pem)
    }

    func tlsConfiguration() throws -> TLSConfiguration {
        TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificateDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)))
    }
}
