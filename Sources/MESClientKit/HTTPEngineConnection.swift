import CryptoKit
import Foundation
import MESCore

/// An engine over HTTP (Base §3): open mode on loopback, or paired mode over TLS with the engine's certificate pinned
/// and a bearer token from pairing.
///
///     let engine = HTTPEngineConnection(baseURL: URL(string: "http://127.0.0.1:17600/mes/v0")!)
///     let job = try await engine.run(JobRequest(operation: "image.generate", inputs: ["prompt": .text("a fox")]))
public final class HTTPEngineConnection: EngineConnection, @unchecked Sendable {
    /// The engine's base URL, including its path (`…/mes/v0`).
    public let baseURL: URL
    public let token: String?
    /// Retries for `429 busy` and `503 no_capacity`, honouring `Retry-After` (capped at `maxRetryDelay`).
    public let maxRetries: Int
    public let maxRetryDelay: Duration

    let session: URLSession
    let trust: EngineTrust
    private let etagCache = Locked<(etag: String, list: OperationsList)?>(nil)

    /// - Parameters:
    ///   - pinnedFingerprint: the engine certificate's SHA-256 (DER) from pairing. Required for `https` unless
    ///     `trustOnFirstUse` is set, which only pairing should do.
    ///   - maxRetries: retries for `busy` and `no_capacity`, waiting `Retry-After` (at most `maxRetryDelay`).
    public init(baseURL: URL, token: String? = nil, pinnedFingerprint: Data? = nil, trustOnFirstUse: Bool = false,
                maxRetries: Int = 2, maxRetryDelay: Duration = .seconds(30), configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        self.token = token
        self.maxRetries = maxRetries
        self.maxRetryDelay = maxRetryDelay
        trust = EngineTrust(pinned: pinnedFingerprint, trustOnFirstUse: trustOnFirstUse)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    /// A connection to a paired engine: its certificate pinned, its token sent.
    public convenience init(paired engine: PairedEngine, maxRetries: Int = 2, configuration: URLSessionConfiguration = .ephemeral) {
        self.init(baseURL: engine.baseURL, token: engine.token, pinnedFingerprint: PairedEngine.data(hex: engine.fingerprintSHA256),
                  maxRetries: maxRetries, configuration: configuration)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// The SHA-256 of the certificate the engine presented, once a TLS connection has been made.
    public var presentedFingerprint: Data? { trust.presented }

    // MARK: - Base operations

    public func engineInfo() async throws -> EngineInfo {
        try decode(EngineInfo.self, try await send("GET", "engine"))
    }

    public func operations() async throws -> OperationsList {
        var headers: [String: String] = [:]
        let cached = etagCache.value
        if let cached { headers["If-None-Match"] = cached.etag }
        let (data, response) = try await send("GET", "operations", headers: headers, accept: [200, 304])
        if response.statusCode == 304, let cached { return cached.list }
        let list = try decode(OperationsList.self, (data, response))
        etagCache.value = (response.value(forHTTPHeaderField: "ETag") ?? list.etag, list)
        return list
    }

    public func health() async throws -> Health { try decode(Health.self, try await send("GET", "health")) }

    public func upload(contentsOf file: URL, mediaType: String) async throws -> Upload {
        let digest = try Self.sha256(of: file)
        let headers = ["Content-Type": mediaType, "Content-Digest": "sha-256=:\(digest.base64EncodedString()):"]
        return try decode(Upload.self, try await send("POST", "uploads", headers: headers, file: file, accept: [201]))
    }

    public func submit(_ request: JobRequest, idempotencyKey: String?) async throws -> Job {
        var headers = ["Content-Type": "application/json"]
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        let body = try MESJSON.encoder.encode(request)
        return try decode(Job.self, try await send("POST", "jobs", headers: headers, body: body, accept: [200, 201]))
    }

    public func job(_ id: String, wait: Int) async throws -> Job {
        let query = wait > 0 ? "?wait=\(min(60, wait))" : ""
        return try decode(Job.self, try await send("GET", "jobs/\(id)\(query)", timeout: TimeInterval(wait + 30)))
    }

    public func jobs(state: JobState? = nil) async throws -> [Job] {
        struct List: Decodable { var jobs: [Job] }
        return try decode(List.self, try await send("GET", "jobs" + (state.map { "?state=\($0.rawValue)" } ?? ""))).jobs
    }

    public func release(_ id: String) async throws -> Job { try decode(Job.self, try await send("DELETE", "jobs/\(id)")) }

    public func confirm(_ id: String) async throws -> Job { try decode(Job.self, try await send("POST", "jobs/\(id)/confirm")) }

    public func download(job: String, output: Output, to destination: URL) async throws -> URL {
        let (temp, response) = try await session.download(for: request("GET", "jobs/\(job)/outputs/\(output.index)"))
        let http = try Self.http(response)
        guard http.statusCode == 200 else {
            let data = (try? Data(contentsOf: temp)) ?? Data()
            try? FileManager.default.removeItem(at: temp)
            throw Self.error(data, http)
        }
        let actual = try Self.sha256(of: temp).map { String(format: "%02x", $0) }.joined()
        guard actual == output.sha256 else {
            try? FileManager.default.removeItem(at: temp)
            throw MESClientError.checksumMismatch(expected: output.sha256, actual: actual)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: - Events (SSE)

    public func events(job id: String, after seq: Int) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var last = seq
                var failures = 0
                while !Task.isCancelled {
                    do {
                        var request = self.request("GET", "jobs/\(id)/events")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        if last > 0 { request.setValue(String(last), forHTTPHeaderField: "Last-Event-ID") }
                        request.timeoutInterval = 120
                        let (bytes, response) = try await self.session.bytes(for: request)
                        let http = try Self.http(response)
                        guard http.statusCode == 200 else {
                            var data = Data()
                            for try await byte in bytes { data.append(byte) }
                            throw Self.error(data, http)
                        }
                        failures = 0
                        var parser = SSEParser()
                        for try await byte in bytes {
                            guard let frame = parser.feed(byte), let data = frame.data.data(using: .utf8) else { continue }
                            let event = try MESJSON.decoder.decode(Event.self, from: data)
                            last = event.seq
                            continuation.yield(event)
                            if event.type == .ended { continuation.finish(); return }
                        }
                    } catch let error as MESClientError {
                        continuation.finish(throwing: error)
                        return
                    } catch {
                        if Task.isCancelled { break }
                        failures += 1
                        if failures > 3 { continuation.finish(throwing: error); return }
                        try? await Task.sleep(for: .milliseconds(250 * failures))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    func url(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)!
    }

    func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue(MESClientKit.baseVersion, forHTTPHeaderField: "MES-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Sends a request, retrying `busy`/`no_capacity` per `Retry-After`. Throws for statuses outside `accept`.
    func send(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil, file: URL? = nil,
              accept: Set<Int> = [200], timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var request = request(method, path)
            request.timeoutInterval = timeout
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let (data, response): (Data, URLResponse)
            if let file {
                (data, response) = try await session.upload(for: request, fromFile: file)
            } else if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
            let http = try Self.http(response)
            if accept.contains(http.statusCode) { return (data, http) }
            let error = Self.error(data, http)
            if case .engine(_, let status, let retryAfter) = error, status == 429 || status == 503, attempt < maxRetries {
                attempt += 1
                let delay = min(Duration.seconds(retryAfter ?? 1), maxRetryDelay)
                try await Task.sleep(for: delay)
                continue
            }
            throw error
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ reply: (Data, HTTPURLResponse)) throws -> T {
        do { return try MESJSON.decoder.decode(T.self, from: reply.0) } catch {
            throw MESClientError.unexpected("Couldn't read \(T.self) from \(reply.1.url?.path ?? "the engine"): \(error)")
        }
    }

    static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw MESClientError.unexpected("Not an HTTP response.") }
        return http
    }

    static func error(_ data: Data, _ response: HTTPURLResponse) -> MESClientError {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        if let body = try? MESJSON.decoder.decode(ErrorBody.self, from: data) {
            return .engine(body.error, status: response.statusCode, retryAfter: retryAfter)
        }
        return .http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
    }

    static func sha256(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }
}

public enum MESClientKit {
    /// The Base version this client speaks, sent as `MES-Version`.
    public static let baseVersion = "0.1"
}

/// Server trust for engines: TLS certificates are self-signed (Base §3.3), so trust comes from the pinned SHA-256 of
/// the certificate, recorded at pairing. Without a pin, only trust-on-first-use (pairing itself) is accepted.
final class EngineTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    let pinned: Data?
    let trustOnFirstUse: Bool
    private let seen = Locked<Data?>(nil)

    init(pinned: Data?, trustOnFirstUse: Bool) {
        self.pinned = pinned
        self.trustOnFirstUse = trustOnFirstUse
    }

    var presented: Data? { seen.value }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        seen.value = fingerprint
        if let pinned {
            completionHandler(pinned == fingerprint ? .useCredential : .cancelAuthenticationChallenge,
                              pinned == fingerprint ? URLCredential(trust: trust) : nil)
        } else if trustOnFirstUse {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Server-Sent Events framing (one byte at a time; `AsyncBytes.lines` drops the empty lines that end events).
struct SSEParser {
    struct Frame { var id: String?; var event: String?; var data: String }
    private var line: [UInt8] = []
    private var id: String?
    private var event: String?
    private var data: [String] = []

    mutating func feed(_ byte: UInt8) -> Frame? {
        guard byte == UInt8(ascii: "\n") else { line.append(byte); return nil }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            defer { id = nil; event = nil; data = [] }
            return data.isEmpty ? nil : Frame(id: id, event: event, data: data.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "id": id = value
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

/// A value behind a lock, for the few mutable fields of otherwise immutable, Sendable types.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&_value) } }
    /// Sets a new value and returns the old one, atomically.
    func swap(_ new: Value) -> Value { withValue { old in defer { old = new }; return old } }
}
