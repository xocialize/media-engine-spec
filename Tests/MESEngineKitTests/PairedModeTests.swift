import Crypto
import Foundation
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Security
import Testing

// Paired mode (Base §3.3, §5) end to end: a real TLS listener with the engine's self-signed certificate, and a
// URLSession client that trusts it on first use and pins it, the way MESClientKit will (R0c).

/// Trusts the server certificate on first use and records its fingerprint; with `pinned` set, accepts only that one.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: Data?
    let pinned: Data?

    init(pinned: Data? = nil) { self.pinned = pinned }

    var seen: Data? { lock.withLock { _seen } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        lock.withLock { _seen = fingerprint }
        if let pinned, pinned != fingerprint {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

struct TLSClient {
    let base: String
    let session: URLSession
    let delegate: PinningDelegate
    var token: String?

    init(port: Int, pinned: Data? = nil, token: String? = nil) {
        base = "https://localhost:\(port)/mes/v0"
        delegate = PinningDelegate(pinned: pinned)
        session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        self.token = token
    }

    func send(_ method: String, _ path: String, json: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.httpBody = json
        if json != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    func code(_ data: Data) -> String? { try? MESJSON.decoder.decode(ErrorBody.self, from: data).error.code }
}

/// Records the engine-side prompts and decides by client name.
actor Operator {
    private(set) var prompts: [PairingPrompt] = []
    func decide(_ prompt: PairingPrompt) async -> Bool {
        prompts.append(prompt)
        if prompt.clientName == "Slow" { try? await Task.sleep(for: .milliseconds(800)) }
        return prompt.clientName != "Mallory"
    }
    func code(for clientID: String) -> String? { prompts.last { $0.clientID == clientID }?.code }
}

func pairedConfig(state: URL? = nil, operator op: Operator) -> EngineConfiguration {
    var c = freshConfig()
    c.mode = .paired
    if let state { c.stateDirectory = state }
    c.pairingApproval = { prompt in await op.decide(prompt) }
    return c
}

func withEngine(_ config: EngineConfiguration, _ body: (Int) async throws -> Void) async throws {
    let server = MESEngineServer(engine: MockImageEngine(), configuration: config)
    let (ports, continuation) = AsyncStream<Int>.makeStream()
    let app = try await server.makeApplication { port in continuation.yield(port) }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await app.runService() }
        var it = ports.makeAsyncIterator()
        guard let port = await it.next() else { return }
        try await body(port)
        group.cancelAll()
    }
}

/// The client side of Base §5: a P-256 key, a nonce, the code computed from both fingerprints.
func pair(_ client: TLSClient, id: String, name: String, wait: Int = 5) async throws
    -> (status: Int, approved: PairingApproved?, clientCode: String, error: String?) {
    let key = P256.Signing.PrivateKey()
    let spki = key.publicKey.derRepresentation
    let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let request = PairingRequest(clientID: id, clientName: name, clientKey: Base64URL.encode(spki), clientNonce: Base64URL.encode(nonce))
    let (status, body) = try await client.send("POST", "/pairings", json: try MESJSON.encoder.encode(request))
    #expect(status == 201)
    let created = try MESJSON.decoder.decode(PairingCreated.self, from: body)
    let fe = try #require(client.delegate.seen)
    let code = PairingCode.code(clientNonce: nonce, engineNonce: try #require(Base64URL.decode(created.engineNonce)),
                                engineFingerprint: fe, clientFingerprint: PairingCode.fingerprint(spki))
    let (cs, cbody) = try await client.send("POST", "/pairings/\(created.pairingID)/confirm", json: Data("{}".utf8),
                                            headers: wait > 0 ? ["Prefer": "wait=\(wait)"] : [:])
    return (cs, cs == 200 ? try MESJSON.decoder.decode(PairingApproved.self, from: cbody) : nil, code, client.code(cbody))
}

@Suite("Paired mode: TLS, pairing, tokens, ownership (Base §3.3, §5)", .serialized)
struct PairedModeTests {
    @Test("Pairing: same code on both sides, a token, then only the client's own jobs")
    func pairingAndOwnership() async throws {
        let op = Operator()
        try await withEngine(pairedConfig(operator: op)) { port in
            var a = TLSClient(port: port)
            let (infoStatus, infoBody) = try await a.send("GET", "/engine")
            #expect(infoStatus == 200)
            let info = try MESJSON.decoder.decode(EngineInfo.self, from: infoBody)
            #expect(info.auth == .paired && info.features.contains(.pairing))
            #expect(info.tls?.fingerprintSHA256 == a.delegate.seen.map(PairingCode.hex), "the advertised fingerprint is the served cert")
            #expect(conforms(.init(bytes: infoBody), to: "base/engine-info.schema.json").isEmpty)

            let (unauth, unauthBody) = try await a.send("GET", "/operations")
            #expect(unauth == 401 && a.code(unauthBody) == "unauthorized")

            let pa = try await pair(a, id: "cli_a", name: "Sam's Desktop")
            #expect(pa.status == 200)
            let engineCode = await op.code(for: "cli_a")
            #expect(engineCode == pa.clientCode, "both screens show the same code")
            a.token = pa.approved?.token
            #expect(try await a.send("GET", "/operations").0 == 200)

            var b = TLSClient(port: port)
            let pb = try await pair(b, id: "cli_b", name: "Priya's Desktop")
            b.token = pb.approved?.token
            #expect(pb.clientCode != pa.clientCode)

            let job = JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: ["size": ["width": 16, "height": 16]])
            let (submitted, jobBody) = try await a.send("POST", "/jobs", json: try MESJSON.encoder.encode(job))
            #expect(submitted == 201)
            let id = try MESJSON.decoder.decode(Job.self, from: jobBody).id
            #expect(try await a.send("GET", "/jobs/\(id)?wait=5").0 == 200)
            let (other, otherBody) = try await b.send("GET", "/jobs/\(id)")
            #expect(other == 404 && b.code(otherBody) == "not_found", "another client can't see the job")
            let listB = try JSONSerialization.jsonObject(with: try await b.send("GET", "/jobs").1) as? [String: Any]
            #expect((listB?["jobs"] as? [Any])?.isEmpty == true)

            var wrong = TLSClient(port: port, token: "mes_tok_not-a-real-token-0000000000")
            #expect(try await wrong.send("GET", "/operations").0 == 401)
            wrong.token = nil

            #expect(try await a.send("DELETE", "/pairings/self").0 == 204)
            #expect(try await a.send("GET", "/operations").0 == 401, "an unpaired token stops working")
            #expect(try await b.send("GET", "/operations").0 == 200)
        }
    }

    @Test("A declined pairing is 403; an undecided one is 202 until the operator answers")
    func approvalOutcomes() async throws {
        let op = Operator()
        try await withEngine(pairedConfig(operator: op)) { port in
            let mallory = try await pair(TLSClient(port: port), id: "cli_m", name: "Mallory")
            #expect(mallory.status == 403 && mallory.error == "pairing_rejected")

            let slowClient = TLSClient(port: port)
            let early = try await pair(slowClient, id: "cli_s", name: "Slow", wait: 0)
            #expect(early.status == 202, "not decided yet")
        }
    }

    @Test("A restart keeps the certificate and the pairings; a client pinned to another certificate is refused")
    func persistenceAndPinning() async throws {
        let op = Operator()
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("mes-state-\(UUID().uuidString)")
        var token: String?
        var fingerprint: Data?
        try await withEngine(pairedConfig(state: state, operator: op)) { port in
            let c = TLSClient(port: port)
            token = try await pair(c, id: "cli_p", name: "Persistent").approved?.token
            fingerprint = c.delegate.seen
        }
        let savedToken = token, savedFingerprint = fingerprint
        try await withEngine(pairedConfig(state: state, operator: op)) { port in
            let pinnedClient = TLSClient(port: port, pinned: savedFingerprint, token: savedToken)
            let (status, _) = try await pinnedClient.send("GET", "/operations")
            #expect(status == 200, "same certificate, same token after a restart")
            let wrongPin = TLSClient(port: port, pinned: Data(repeating: 7, count: 32), token: savedToken)
            var refused = false
            do { _ = try await wrongPin.send("GET", "/engine") } catch { refused = true }
            #expect(refused, "a different certificate is refused")
        }
    }

    @Test("DNS-SD TXT record carries the spec's keys")
    func txtRecord() {
        var c = freshConfig()
        c.mode = .paired
        let txt = EngineAdvertiser.txt(config: c, profiles: [.init(id: "image", versions: ["0.1"])])
        #expect(txt == ["txtvers": "1", "mes": "0.1", "profiles": "image/0.1", "id": "eng_test", "auth": "paired",
                        "tls": "1", "path": "/mes/v0", "ver": "0.1.0"])
        let record = EngineAdvertiser.txtRecord(["a": "1", "bb": "22"])
        #expect(Array(record) == [3] + Array("a=1".utf8) + [5] + Array("bb=22".utf8))
    }
}
