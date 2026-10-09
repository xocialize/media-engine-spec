import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import MESCore
@_exported import MESEngineCore
import NIOCore

/// Serves a `MediaEngine` over MES Base 0.1: HTTP, SSE, the WebSocket channel and the MCP binding, in open or
/// paired mode.
///
///     let server = MESEngineServer(engine: MyEngine(), configuration: config)
///     try await server.run { port in print("listening on \(port)") }
public final class MESEngineServer: Sendable {
    public let configuration: EngineConfiguration
    let engine: any MediaEngine
    private let advertiser = EngineAdvertiser()

    public init(engine: any MediaEngine, configuration: EngineConfiguration) {
        self.engine = engine
        self.configuration = configuration
    }

    /// Prepares the spool (wiping leftovers, Base §13 rule 3), loads descriptors, starts the retention sweeper and,
    /// in paired mode, the TLS identity and pairings. Returns the Hummingbird application.
    public func makeApplication(onRunning: @escaping @Sendable (Int) async -> Void = { _ in }) async throws
        -> some ApplicationProtocol {
        let config = configuration
        let (spool, _) = try Spool.prepare(at: config.spoolDirectory)
        let registry = JobRegistry(engine: engine, config: config, spool: spool)
        var identity: EngineIdentity?
        var pairings: PairingRegistry?
        if config.mode == .paired {
            let id = try EngineIdentity.loadOrCreate(in: config.stateDirectory, commonName: "MES engine \(config.id)")
            pairings = PairingRegistry(stateDirectory: config.stateDirectory, identity: id, approve: config.pairingApproval)
            identity = id
        }
        await registry.start(tlsFingerprint: identity?.fingerprintHex)
        let router = Routes.router(registry: registry, pairings: pairings, config: config, spool: spool)
        // The same router answers WebSocket upgrades, so `{path}/ws` runs the guard and auth middleware first.
        let idle = TimeAmount.nanoseconds(Int64(config.idleTimeout.components.seconds) * 1_000_000_000
            + config.idleTimeout.components.attoseconds / 1_000_000_000)
        var server: HTTPServerBuilder = .http1WebSocketUpgrade(
            webSocketRouter: router, configuration: .init(http1: .init(idleTimeout: idle), ws: .init()))
        if let identity { server = try .tls(server, tlsConfiguration: try identity.tlsConfiguration()) }
        let advertiser = self.advertiser
        let profiles = await registry.engineInfo().profiles
        return Application(
            router: router,
            server: server,
            configuration: .init(address: .hostname(config.host, port: config.port), serverName: "mes-engine"),
            onServerRunning: { channel in
                let port = channel.localAddress?.port ?? 0
                if config.advertise {
                    advertiser.start(name: config.name, port: port, txt: EngineAdvertiser.txt(config: config, profiles: profiles),
                                     localOnly: config.mode == .open || ["127.0.0.1", "localhost", "::1"].contains(config.host))
                }
                await onRunning(port)
            })
    }

    public func run(onRunning: @escaping @Sendable (Int) async -> Void = { _ in }) async throws {
        defer { advertiser.stop() }
        try await makeApplication(onRunning: onRunning).runService()
    }

    /// Stops advertising (the listener stops with the application's service).
    public func stopAdvertising() { advertiser.stop() }
}

// MARK: - Context and headers

public struct MESRequestContext: RequestContext, RemoteAddressRequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: SocketAddress?
    public let webSocket: WebSocketHandlerReference<MESRequestContext>
    public var requestID: String = IDs.make("req_", length: 12)
    /// Who owns the jobs this request sees. Open mode has one local client; paired mode uses the pairing.
    public var clientID: String = "local"

    public init(source: Source) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
        webSocket = .init()
    }

    public var peerHost: String? { remoteAddress?.ipAddress }

    public var isLoopback: Bool {
        guard let address = remoteAddress else { return false }
        switch address {
        case .v4(let a): return a.host.hasPrefix("127.")
        case .v6(let a): return a.host == "::1" || a.host.hasPrefix("::ffff:127.")
        case .unixDomainSocket: return true
        }
    }
}

extension HTTPField.Name {
    static let mesVersion = Self("MES-Version")!
    static let mesRequestID = Self("MES-Request-Id")!
    static let lastEventID = Self("Last-Event-ID")!
    static let idempotencyKey = Self("Idempotency-Key")!
    static let contentDigest = Self("Content-Digest")!
    static let prefer = Self("Prefer")!
}

// MARK: - Responses

enum Responses {
    static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]) throws -> Response {
        var h = headers
        h[.contentType] = "application/json"
        let data = try MESJSON.encoder.encode(value)
        return Response(status: status, headers: h, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func error(_ error: MESError, requestID: String) -> Response {
        var e = error
        e.requestID = requestID
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.mesRequestID] = requestID
        headers[.mesVersion] = EngineConfiguration.baseVersions.last
        if e.code == MESErrorCode.busy.rawValue || e.code == MESErrorCode.noCapacity.rawValue { headers[.retryAfter] = "10" }
        let data = (try? MESJSON.encoder.encode(ErrorBody(error: e))) ?? Data()
        return Response(status: HTTPResponse.Status(code: e.status), headers: headers,
                        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

// MARK: - Middleware

/// Outermost: turns every failure into the §12 error body, and stamps MES headers on every response.
struct ErrorMiddleware: RouterMiddleware {
    typealias Context = MESRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            var response = try await next(request, context)
            response.headers[.mesRequestID] = context.requestID
            response.headers[.mesVersion] = EngineConfiguration.baseVersions.last
            return response
        } catch let error as MESError {
            return Responses.error(error, requestID: context.requestID)
        } catch let error as HTTPError {
            let mapped: MESError = switch error.status.code {
            case 404: MESError(.notFound, "No such endpoint: \(request.method) \(request.uri.path).")
            case 405: MESError(.notFound, "\(request.method) isn't supported on \(request.uri.path).")
            case 413: MESError(.tooLarge, "The request body is too large.")
            case 400..<500: MESError(.invalidRequest, error.body ?? "Bad request.")
            default: MESError(.engineError, error.body ?? "Engine error.")
            }
            return Responses.error(mapped, requestID: context.requestID)
        } catch let error as DecodingError {
            return Responses.error(MESError(.invalidRequest, "Malformed JSON: \(Self.describe(error))"), requestID: context.requestID)
        } catch {
            return Responses.error(MESError(.engineError, "\(error)"), requestID: context.requestID)
        }
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }
}

/// Origin allowlist (§3.2), open-mode loopback rule (§3.3), version negotiation (§2).
struct GuardMiddleware: RouterMiddleware {
    typealias Context = MESRequestContext
    let config: EngineConfiguration

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        if let origin = request.headers[.origin], !config.allowedOrigins.contains(origin) {
            throw MESError(.originNotAllowed, "Requests from \(origin) are not allowed.")
        }
        if config.mode == .open, !context.isLoopback {
            throw MESError(.forbidden, "This engine runs in open mode and accepts loopback requests only.")
        }
        if let version = request.headers[.mesVersion], !EngineConfiguration.baseVersions.contains(version) {
            var e = MESError(.unsupportedVersion, "MES-Version \(version) isn't supported.")
            e.supportedVersions = EngineConfiguration.baseVersions
            throw e
        }
        return try await next(request, context)
    }
}

/// Paired mode (Base §3.3): every endpoint except the handshake and the pairing exchange needs a bearer token, which
/// names the client that owns the jobs it sees.
struct PairedAuthMiddleware: RouterMiddleware {
    typealias Context = MESRequestContext
    let pairings: PairingRegistry
    let basePath: String

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let open = (request.method == .get && path == basePath + "/engine")
            || (request.method == .post && path == basePath + "/pairings")
            || (request.method == .post && path.hasPrefix(basePath + "/pairings/") && path.hasSuffix("/confirm"))
        if open { return try await next(request, context) }
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let client = await pairings.client(forToken: String(header.dropFirst("Bearer ".count))) else {
            throw MESError(.unauthorized, "Pair with this engine first, then send Authorization: Bearer <token>.")
        }
        var paired = context
        paired.clientID = client
        return try await next(request, paired)
    }
}

// MARK: - Routes

enum Routes {
    static func router(registry: JobRegistry, pairings: PairingRegistry?, config: EngineConfiguration,
                       spool: Spool) -> Router<MESRequestContext> {
        let router = Router(context: MESRequestContext.self)
        router.add(middleware: ErrorMiddleware())
        router.add(middleware: GuardMiddleware(config: config))
        if let pairings { router.add(middleware: PairedAuthMiddleware(pairings: pairings, basePath: config.basePath)) }
        let api = router.group(RouterPath(config.basePath))
        let fileIO = FileIO()

        if let pairings {
            api.post("pairings") { request, _ in
                let body = try await request.body.collect(upTo: 64 << 10)
                let pairingRequest = try MESJSON.decoder.decode(PairingRequest.self, from: Data(body.readableBytesView))
                return try Responses.json(try await pairings.create(pairingRequest), status: .created)
            }
            api.post("pairings/:id/confirm") { request, context in
                let wait = min(60, max(0, Self.preferWait(request.headers[.prefer]) ?? 0))
                switch try await pairings.confirm(try context.parameters.require("id"), wait: wait) {
                case .awaiting: return try Responses.json(["state": "awaiting_approval"], status: .accepted)
                case .approved(let approved): return try Responses.json(approved)
                }
            }
            api.delete("pairings/self") { _, context in
                await pairings.unpair(context.clientID)
                return Response(status: .noContent)
            }
        }

        api.get("engine") { _, _ in try Responses.json(await registry.engineInfo()) }

        api.get("health") { _, _ in try Responses.json(await registry.health()) }

        api.get("operations") { request, _ in
            let list = await registry.operationsList
            var headers = HTTPFields()
            headers[.eTag] = list.etag
            if let inm = request.headers[.ifNoneMatch], inm == list.etag {
                return Response(status: .notModified, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer()))
            }
            return try Responses.json(list, headers: headers)
        }

        api.get("operations/:operation") { _, context in
            let op = try context.parameters.require("operation")
            guard let descriptor = await registry.descriptors[op] else {
                throw MESError(.unknownOperation, "No operation \(op) on this engine.")
            }
            return try Responses.json(descriptor)
        }

        api.post("uploads") { request, context in
            let mediaType = request.headers[.contentType]?.split(separator: ";").first.map {
                String($0).trimmingCharacters(in: .whitespaces).lowercased()
            } ?? "application/octet-stream"
            let id = IDs.make("upl_")
            let file = spool.uploadFile(id)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            var hasher = SHA256()
            var total = 0
            do {
                for try await buffer in request.body {
                    total += buffer.readableBytes
                    if total > config.maxUploadBytes {
                        throw MESError(.tooLarge, "Uploads are limited to \(config.maxUploadBytes) bytes.")
                    }
                    let bytes = Data(buffer.readableBytesView)
                    hasher.update(data: bytes)
                    try handle.write(contentsOf: bytes)
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let digest = request.headers[.contentDigest], let expected = Self.sha256Digest(digest), expected != sha {
                try? FileManager.default.removeItem(at: file)
                throw MESError(.invalidRequest, "Content-Digest doesn't match the uploaded bytes.")
            }
            let upload = await registry.createUpload(owner: context.clientID, mediaType: mediaType, file: file,
                                                     bytes: total, sha256: sha)
            return try Responses.json(upload, status: .created)
        }

        api.post("jobs") { request, context in
            let body = try await request.body.collect(upTo: config.maxJSONBodyBytes)
            let jobRequest = try MESJSON.decoder.decode(JobRequest.self, from: Data(body.readableBytesView))
            let job = try await registry.submit(jobRequest, owner: context.clientID, clientHost: context.peerHost,
                                                idempotencyKey: request.headers[.idempotencyKey])
            var headers = HTTPFields()
            headers[.location] = "\(config.basePath)/jobs/\(job.id)"
            return try Responses.json(job, status: .created, headers: headers)
        }

        api.get("jobs") { request, context in
            let state = request.uri.queryParameters.get("state").flatMap(JobState.init(rawValue:))
            return try Responses.json(["jobs": await registry.list(owner: context.clientID, state: state)])
        }

        api.get("jobs/:id") { request, context in
            let id = try context.parameters.require("id")
            let wait = min(60, max(0, request.uri.queryParameters.get("wait", as: Int.self) ?? 0))
            return try Responses.json(try await registry.waitForChange(id, owner: context.clientID, seconds: wait))
        }

        api.delete("jobs/:id") { _, context in
            try Responses.json(try await registry.release(try context.parameters.require("id"), owner: context.clientID))
        }

        api.post("jobs/:id/confirm") { _, context in
            try Responses.json(try await registry.confirm(try context.parameters.require("id"), owner: context.clientID))
        }

        api.get("jobs/:id/outputs/:index") { request, context in
            let id = try context.parameters.require("id")
            guard let index = Int(try context.parameters.require("index")) else {
                throw MESError(.notFound, "Output index must be a number.")
            }
            let (file, output) = try await registry.output(id, index: index, owner: context.clientID)
            return try await FileServing.response(for: file, mediaType: output.mediaType, etag: "\"sha256:\(output.sha256)\"",
                                                  request: request, context: context, fileIO: fileIO)
        }

        api.get("jobs/:id/events") { request, context in
            let id = try context.parameters.require("id")
            let after = request.headers[.lastEventID].flatMap(Int.init) ?? 0
            let events = try await registry.subscribe(id, owner: context.clientID, after: after)
            return SSE.response(events: events, heartbeat: config.heartbeat)
        }

        api.ws("ws") { inbound, outbound, wsContext in
            await EventSocket.serve(inbound: inbound, outbound: outbound, client: wsContext.requestContext.clientID,
                                        registry: registry, healthInterval: config.heartbeat)
        }

        let sessions = MCPSessions(toolbox: MCPToolbox(registry: registry, config: config))
        let scheme = config.mode == .paired ? "https" : "http"
        let mcp: @Sendable (Request, MESRequestContext) async throws -> Response = { request, context in
            let body = try await request.body.collect(upTo: config.maxJSONBodyBytes)
            var headers: [String: String] = [:]
            for field in request.headers { headers[field.name.rawName] = field.value }
            let authority = request.head.authority ?? "\(config.host):\(config.port)"
            let reply = await sessions.handle(method: request.method.rawValue, headers: headers,
                                              body: body.readableBytes > 0 ? Data(body.readableBytesView) : nil,
                                              path: request.uri.path, client: context.clientID, clientHost: context.peerHost,
                                              baseURL: "\(scheme)://\(authority)")
            return MCPResponses.response(reply)
        }
        api.post("mcp", use: mcp)
        api.get("mcp", use: mcp)
        api.delete("mcp", use: mcp)

        return router
    }

    /// `Prefer: wait=30` → 30.
    static func preferWait(_ header: String?) -> Int? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.lowercased().hasPrefix("wait=") { return Int(kv.dropFirst(5)) }
        }
        return nil
    }

    /// `sha-256=:<base64>:` → hex.
    static func sha256Digest(_ header: String) -> String? {
        for part in header.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            guard kv.lowercased().hasPrefix("sha-256=:"), kv.hasSuffix(":") else { continue }
            let b64 = kv.dropFirst("sha-256=:".count).dropLast()
            guard let data = Data(base64Encoded: String(b64)) else { return nil }
            return data.map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }
}

// MARK: - MCP (§15)

enum MCPResponses {
    static func response(_ reply: MCPReply) -> Response {
        var fields = HTTPFields()
        for (name, value) in reply.headers {
            if let field = HTTPField.Name(name) { fields[field] = value }
        }
        let status = HTTPResponse.Status(code: reply.status)
        switch reply.body {
        case .empty:
            return Response(status: status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer()))
        case .data(let data):
            return Response(status: status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
        case .stream(let stream):
            return Response(status: status, headers: fields, body: ResponseBody { writer in
                do {
                    for try await chunk in stream { try await writer.write(ByteBuffer(bytes: chunk)) }
                } catch {}
                try await writer.finish(nil)
            })
        }
    }
}

// MARK: - SSE (§11)

enum SSE {
    static func response(events: AsyncStream<Event>, heartbeat: Duration) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: ResponseBody(asyncSequence: frames(events, heartbeat)))
    }

    static func frames(_ events: AsyncStream<Event>, _ heartbeat: Duration) -> AsyncStream<ByteBuffer> {
        let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        let pump = Task {
            for await event in events {
                guard let data = try? MESJSON.encoder.encode(event) else { continue }
                continuation.yield(ByteBuffer(string: "id: \(event.seq)\nevent: \(event.type.rawValue)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"))
            }
            continuation.finish()
        }
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: heartbeat)
                if Task.isCancelled { break }
                continuation.yield(ByteBuffer(string: ": heartbeat\n\n"))
            }
        }
        continuation.onTermination = { _ in pump.cancel(); beat.cancel() }
        return stream
    }
}

// MARK: - Ranged output files (§7.3)

/// Adapted from ML[X] Image Server's FileServing (same author).
enum FileServing {
    static func response(for url: URL, mediaType: String, etag: String, request: Request, context: MESRequestContext,
                         fileIO: FileIO) async throws -> Response {
        var headers = HTTPFields()
        headers[.acceptRanges] = "bytes"
        headers[.eTag] = etag
        headers[.cacheControl] = "private, no-store"
        headers[.contentType] = mediaType
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = (attrs[.size] as? NSNumber)?.intValue else {
            throw MESError(.gone, "The output is no longer available.")
        }
        if let header = request.headers[.range], total > 0 {
            guard let range = parseByteRange(header, total: total) else {
                headers[.contentRange] = "bytes */\(total)"
                return Response(status: .rangeNotSatisfiable, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer()))
            }
            headers[.contentRange] = "bytes \(range.lowerBound)-\(range.upperBound)/\(total)"
            let body = try await fileIO.loadFile(path: url.path, range: range, context: context)
            return Response(status: .partialContent, headers: headers, body: body)
        }
        let body = try await fileIO.loadFile(path: url.path, context: context)
        return Response(status: .ok, headers: headers, body: body)
    }

    /// A single `bytes=` range, clamped and inclusive; nil when unsatisfiable. Multiple ranges are refused.
    static func parseByteRange(_ header: String, total: Int) -> ClosedRange<Int>? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard total > 0, spec.lowercased().hasPrefix("bytes=") else { return nil }
        let value = String(spec.dropFirst("bytes=".count))
        guard !value.contains(",") else { return nil }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let count = Int(last), count > 0 else { return nil }
            return max(0, total - count)...(total - 1)
        }
        guard let start = Int(first), start >= 0, start < total else { return nil }
        guard !last.isEmpty else { return start...(total - 1) }
        guard let end = Int(last), end >= start else { return nil }
        return start...min(end, total - 1)
    }
}
