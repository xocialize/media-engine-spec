import CryptoKit
import Foundation
import MESCore
import Network

/// Serves files to engines that pull inputs (Base §9), for clients that keep custody of their media (Desktop's
/// library). Each grant is one file behind a random bearer token; the engine fetches it with
/// `Authorization: Bearer <token>`. Revoke the grant once its job leaves `running` (§9 rule 4).
///
/// A minimal HTTP/1.1 server on Network.framework: `GET /grants/<id>` only, one request per connection.
///
///     let grants = GrantServer()
///     let port = try await grants.start()
///     let grant = try grants.grant(file, mediaType: "image/png", host: "127.0.0.1")
///     request.inputs = ["image": .one(.grant(grant))]
public final class GrantServer: Sendable {
    struct Entry { let file: URL; let mediaType: String; let bytes: Int; let token: String }

    private let entries = Locked<[String: Entry]>([:])
    private let listener = Locked<NWListener?>(nil)
    private let boundPort = Locked<UInt16?>(nil)
    private let queue = DispatchQueue(label: "mes.client.grants")
    private let loopbackOnly: Bool

    /// - Parameter loopbackOnly: serve only this machine (an engine on loopback). A LAN engine needs `false`.
    public init(loopbackOnly: Bool = true) { self.loopbackOnly = loopbackOnly }

    /// Starts listening on `port` (0 picks one) and returns the bound port.
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        let listener = try loopbackOnly ? NWListener(using: parameters)
            : NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener.value = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let started = Locked(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.boundPort.value = port
                    if started.swap(true) == false { continuation.resume(returning: port) }
                case .failed(let error):
                    if started.swap(true) == false { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.value?.cancel()
        listener.value = nil
    }

    /// The port, once started.
    public var port: UInt16? { boundPort.value }

    /// Grants `file` to an engine. `host` is this machine's address as the engine sees it (`127.0.0.1` for a
    /// loopback engine): engines fetch only from the host that submitted the job (§9 rule 2).
    public func grant(_ file: URL, mediaType: String, host: String) throws -> Grant {
        guard let port else { throw MESClientError.unexpected("Start the grant server first.") }
        let digest = try HTTPEngineConnection.sha256(of: file)
        let bytes = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let id = Self.random(12)
        let token = "mes_grant_" + Self.random(32)
        entries.withValue { $0[id] = Entry(file: file, mediaType: mediaType, bytes: bytes, token: token) }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return Grant(url: "http://\(hostPart):\(port)/grants/\(id)", token: token, mediaType: mediaType, bytes: bytes,
                     sha256: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// Ends a grant: later fetches answer 404.
    public func revoke(_ grant: Grant) {
        guard let id = grant.url.split(separator: "/").last.map(String.init) else { return }
        entries.withValue { $0[id] = nil }
    }

    /// Grants currently open.
    public var count: Int { entries.value.count }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if isComplete || error != nil || buffer.count > 16 << 10 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard request.count >= 2, request[0] == "GET", request[1].hasPrefix("/grants/") else {
            return status(connection, 404, "Not Found")
        }
        let id = String(request[1].dropFirst("/grants/".count))
        guard let entry = entries.value[id] else { return status(connection, 404, "Not Found") }
        guard headers["authorization"] == "Bearer \(entry.token)" else { return status(connection, 401, "Unauthorized") }
        guard let handle = try? FileHandle(forReadingFrom: entry.file) else { return status(connection, 410, "Gone") }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(entry.mediaType)\r\nContent-Length: \(entry.bytes)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendBody(connection, handle)
        })
    }

    private func sendBody(_ connection: NWConnection, _ handle: FileHandle) {
        let chunk = (try? handle.read(upToCount: 256 << 10)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            self?.sendBody(connection, handle)
        })
    }

    private func status(_ connection: NWConnection, _ code: Int, _ reason: String) {
        let response = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    static func random(_ bytes: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &g) }))
    }
}
