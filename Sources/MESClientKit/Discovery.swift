import Foundation
import MESCore
import Network

/// An engine found over DNS-SD (Base §3.1), with its TXT record read.
public struct DiscoveredEngine: Sendable, Hashable, Identifiable {
    /// The engine's id from TXT `id`, or the service name when missing.
    public var id: String { engineID ?? serviceName }
    public let serviceName: String
    public let engineID: String?
    public let auth: AuthMode?
    public let tls: Bool
    public let path: String
    /// `image/0.1`, …
    public let profiles: [String]
    public let baseVersions: [String]
    public let version: String?
    public let txt: [String: String]
    let endpoint: NWEndpoint

    init(endpoint: NWEndpoint, txt: [String: String]) {
        self.endpoint = endpoint
        if case .service(let name, _, _, _) = endpoint { serviceName = name } else { serviceName = "\(endpoint)" }
        self.txt = txt
        engineID = txt["id"]
        auth = txt["auth"].flatMap(AuthMode.init(rawValue:))
        tls = txt["tls"] == "1"
        path = txt["path"] ?? "/mes/v0"
        profiles = txt["profiles"]?.split(separator: ",").map(String.init) ?? []
        baseVersions = txt["mes"]?.split(separator: ",").map(String.init) ?? []
        version = txt["ver"]
    }

    /// Resolves the service to a base URL (`https://host:port/mes/v0` for TLS engines). Prefers IPv4.
    public func resolve(timeout: Duration = .seconds(5)) async throws -> URL {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let scheme = tls ? "https" : "http"
        let path = self.path
        let once = Locked(false)
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            @Sendable func finish(_ result: Result<URL, any Error>) {
                if once.swap(true) == false { continuation.resume(with: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint,
                          let url = URL(string: "\(scheme)://\(Self.format(host)):\(port.rawValue)\(path)") else {
                        finish(.failure(MESClientError.unexpected("Couldn't resolve \(self.serviceName).")))
                        return
                    }
                    finish(.success(url))
                case .failed(let error), .waiting(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                finish(.failure(MESClientError.unexpected("Resolving \(self.serviceName) timed out.")))
            }
        }
    }

    /// A URL host. Addresses are formatted from their bytes: their descriptions carry an interface suffix
    /// (`127.0.0.1%lo0`), which a URL allows only for IPv6, as a `%25` zone.
    static func format(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let text = address.rawValue.withUnsafeBytes { bytes in
                inet_ntop(AF_INET6, bytes.baseAddress, &buffer, socklen_t(buffer.count)).map { _ in
                    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                } ?? "::1"
            }
            let zone = address.isLinkLocal ? address.interface.map { "%25" + $0.name } ?? "" : ""
            return "[\(text)\(zone)]"
        case .name(let name, _): return name
        @unknown default: return "\(host)"
        }
    }
}

/// Browses `_mes-engine._tcp` (Base §3.1).
///
///     for await engines in EngineBrowser.browse() { show(engines) }
public enum EngineBrowser {
    public static let serviceType = "_mes-engine._tcp"

    /// The current set of engines, updated as they come and go, until the stream is cancelled.
    public static func browse(domain: String? = nil) -> AsyncStream<[DiscoveredEngine]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: domain), using: .tcp)
            browser.browseResultsChangedHandler = { results, _ in
                let engines = results.map { result -> DiscoveredEngine in
                    var txt: [String: String] = [:]
                    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
                    return DiscoveredEngine(endpoint: result.endpoint, txt: txt)
                }
                continuation.yield(engines.sorted { $0.serviceName < $1.serviceName })
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: .global())
        }
    }

    /// Browses for `seconds` and returns what was found.
    public static func discover(for seconds: Duration = .seconds(2)) async -> [DiscoveredEngine] {
        let latest = Locked<[DiscoveredEngine]>([])
        let task = Task { for await engines in browse() { latest.value = engines } }
        try? await Task.sleep(for: seconds)
        task.cancel()
        return latest.value
    }
}
