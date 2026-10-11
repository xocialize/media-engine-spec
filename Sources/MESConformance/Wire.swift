import CryptoKit
import Foundation
import MESCore

/// Raw HTTP to the engine under test. The suite checks the wire itself (statuses, headers, bodies, framing), so it
/// doesn't go through MESClientKit, which would smooth those over.
public final class Wire: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public struct Reply: Sendable {
        public var status: Int
        /// Lower-cased header names.
        public var headers: [String: String]
        public var body: Data
        public func header(_ name: String) -> String? { headers[name.lowercased()] }
        public var json: JSONValue? { try? MESJSON.decoder.decode(JSONValue.self, from: body) }
        public func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do { return try MESJSON.decoder.decode(T.self, from: body) } catch {
                throw Failure("Couldn't read \(T.self) from the response (\(status)): \(String(decoding: body.prefix(300), as: UTF8.self))")
            }
        }
        /// The §12 error code, if the body is an error body.
        public var errorCode: String? { json?["error"]?["code"]?.stringValue }
    }

    public let baseURL: URL
    public let token: String?
    private let pinned: Data?
    private let lock = NSLock()
    private var _presented: Data?
    private var session: URLSession!

    /// - Parameters:
    ///   - pinned: the engine certificate's SHA-256 for TLS engines; nil trusts what's presented (pairing, or an
    ///     engine whose identity BASE-006 then checks against its handshake).
    public init(baseURL: URL, token: String? = nil, pinned: Data? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.pinned = pinned
        super.init()
        // No cache: URLSession would answer a 304 from its cache as a 200, hiding the engine's revalidation.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The SHA-256 of the certificate the engine presented, after a TLS request.
    public var presentedFingerprint: Data? { lock.withLock { _presented } }

    public func with(token: String?) -> Wire { Wire(baseURL: baseURL, token: token, pinned: pinned ?? presentedFingerprint) }

    public func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!
    }

    public func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
                        authorized: Bool = true, timeout: TimeInterval = 60) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("0.1", forHTTPHeaderField: "MES-Version")
        if authorized, let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        return r
    }

    public func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil,
                     authorized: Bool = true, timeout: TimeInterval = 60) async throws -> Reply {
        try await send(request(method, path, headers: headers, body: body, authorized: authorized, timeout: timeout))
    }

    public func send(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure("Not an HTTP response.") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return Reply(status: http.statusCode, headers: headers, body: data)
    }

    public func json<T: Encodable>(_ method: String, _ path: String, _ value: T, headers: [String: String] = [:]) async throws -> Reply {
        var h = headers
        h["Content-Type"] = "application/json"
        return try await send(method, path, headers: h, body: try MESJSON.encoder.encode(value))
    }

    // MARK: - SSE

    public struct Frame: Sendable { public var id: String?; public var event: String?; public var data: String }

    /// Reads SSE frames until `stop` says so, the stream ends, or `timeout` passes. Returns the response's content type,
    /// the frames, and whether the stream ended by itself.
    public func frames(_ path: String, lastEventID: Int? = nil, timeout: TimeInterval = 30,
                       stop: @Sendable @escaping (Frame) -> Bool = { _ in false }) async throws
        -> (contentType: String?, frames: [Frame], ended: Bool) {
        var r = request("GET", path, headers: ["Accept": "text/event-stream"], timeout: timeout)
        if let lastEventID { r.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await session.bytes(for: r)
        guard let http = response as? HTTPURLResponse else { throw Failure("Not an HTTP response.") }
        guard http.statusCode == 200 else { throw Failure("The event stream answered \(http.statusCode).") }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        return try await withThrowingTaskGroup(of: ([Frame], Bool).self) { group in
            group.addTask {
                var frames: [Frame] = []
                var line: [UInt8] = []
                var current = Frame(data: "")
                var data: [String] = []
                for try await byte in bytes {
                    guard byte == 10 else { line.append(byte); continue }
                    if line.last == 13 { line.removeLast() }
                    let text = String(decoding: line, as: UTF8.self)
                    line = []
                    if text.isEmpty {
                        if !data.isEmpty {
                            current.data = data.joined(separator: "\n")
                            frames.append(current)
                            if stop(current) { return (frames, false) }
                        }
                        current = Frame(data: "")
                        data = []
                    } else if !text.hasPrefix(":") {
                        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                        var value = parts.count > 1 ? String(parts[1]) : ""
                        if value.hasPrefix(" ") { value.removeFirst() }
                        switch parts[0] {
                        case "id": current.id = value
                        case "event": current.event = value
                        case "data": data.append(value)
                        default: break
                        }
                    }
                }
                return (frames, true)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Failure("The event stream didn't finish within \(Int(timeout)) s.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return (contentType, result.0, result.1)
        }
    }

    // MARK: - WebSocket

    public func webSocket(_ path: String, headers: [String: String] = [:]) -> URLSessionWebSocketTask {
        var components = URLComponents(url: url(path), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var r = URLRequest(url: components.url!)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: r)
        task.resume()
        return task
    }

    // MARK: - Trust

    // Both challenge methods: async `bytes(for:)` delivers the server-trust challenge to the task-level one only.
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        evaluate(challenge, completionHandler)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge,
                          _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        lock.withLock { _presented = fingerprint }
        if let pinned, pinned != fingerprint {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

/// A conformance check that failed, with what was expected and what was seen.
public struct Failure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ message: String) { description = message }
}

/// Fails the current test unless `condition` holds.
public func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(message()) }
}

/// Fails unless `reply` has `status` (and, when given, the §12 `code` with a schema-valid error body).
public func expect(_ reply: Wire.Reply, _ status: Int, code: String? = nil, _ what: String, schemas: Schemas) throws {
    try check(reply.status == status, "\(what): expected \(status)\(code.map { " \($0)" } ?? ""), got \(reply.status) \(reply.errorCode ?? "") \(String(decoding: reply.body.prefix(200), as: UTF8.self))")
    if let code {
        try check(reply.errorCode == code, "\(what): expected error code \(code), got \(reply.errorCode ?? "none")")
        try schemas.require(reply.body, "base/error.schema.json", what)
    }
}

enum Hex {
    static func string(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ data: Data) -> String { string(Data(SHA256.hash(data: data))) }
    static func data(_ hex: String) -> Data? {
        var bytes = [UInt8]()
        var it = hex.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }
}
