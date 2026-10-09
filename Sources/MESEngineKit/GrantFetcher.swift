import Foundation
import MESCore

/// Pulls a granted input from the client's media server (Base §9): bearer token, no redirects, checksum verified,
/// and only from the host that submitted the job, so an engine can't be used to reach other hosts.
enum GrantFetcher {
    static func fetch(_ grant: Grant, to file: URL, clientHost: String?, maxBytes: Int) async throws {
        guard let url = URL(string: grant.url), let host = url.host, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MESError(.inputInvalid, "Grant URL \(grant.url) is not an http(s) URL.")
        }
        guard hostAllowed(host, clientHost: clientHost) else {
            throw MESError(.inputInvalid, "Grant URLs must point at the host that submitted the job.",
                           reason: "grant host \(host), client \(clientHost ?? "unknown")")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(grant.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        } catch {
            throw MESError(.inputFetchFailed, "Fetching the grant failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MESError(.inputFetchFailed, "The grant was refused (\(status)).")
        }
        guard data.count <= maxBytes else { throw MESError(.tooLarge, "The granted input exceeds \(maxBytes) bytes.") }
        if let expected = grant.sha256, Hashing.sha256(data) != expected {
            throw MESError(.inputFetchFailed, "The granted input doesn't match its sha256.")
        }
        try data.write(to: file)
    }

    static func hostAllowed(_ host: String, clientHost: String?) -> Bool {
        guard let client = clientHost?.lowercased() else { return false }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let clientIsLoopback = client.hasPrefix("127.") || client == "::1" || client.hasPrefix("::ffff:127.")
        if clientIsLoopback { return h == "localhost" || h == "::1" || h.hasPrefix("127.") }
        return h == client || "::ffff:\(h)" == client
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
