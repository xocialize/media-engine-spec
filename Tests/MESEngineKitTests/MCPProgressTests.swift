import Foundation
@testable import MESEngineKit
import Testing

// Progress over MCP (Base §15) at the HTTP level, without the SDK client's timing: the standalone stream opens on a
// session's first GET even when that GET names another stream's event, and progress sent before it opens still arrives.

/// A raw MCP session on a live engine: Streamable HTTP POSTs, and the standalone GET stream read line by line.
struct RawMCP {
    let endpoint: URL
    var session: String?
    /// The event id initialize's response stream carried (its priming event), as the swift-sdk client remembers it.
    var initializeEventID: String?

    init(port: Int) { endpoint = URL(string: "http://127.0.0.1:\(port)/mes/v0/mcp")! }

    func request(_ method: String, body: String? = nil, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = method
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let session { r.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let body { r.httpBody = Data(body.utf8); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    mutating func initialize() async throws {
        let (data, response) = try await URLSession.shared.data(for: request("POST", body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"raw","version":"0.1"}}}"#))
        session = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
        initializeEventID = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("id:") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        _ = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    func post(_ body: String) async throws -> String {
        String(decoding: try await URLSession.shared.data(for: request("POST", body: body)).0, as: UTF8.self)
    }

    /// Generates a tiny image with a progress token; returns when the call's response arrives.
    func generate(token: String) async throws -> String {
        try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"image_generate","arguments":{"prompt":"x","size":{"width":16,"height":16}},"_meta":{"progressToken":"\#(token)"}}}"#)
    }

    /// Opens the standalone stream and collects progress values for `token` until 100, or until `timeout`.
    func progress(token: String, lastEventID: String? = nil, timeout: Duration = .seconds(5),
                  whileOpen: @escaping @Sendable () async throws -> Void = {}) async throws -> (status: Int, values: [Double]) {
        let get = request("GET", headers: lastEventID.map { ["Last-Event-ID": $0] } ?? [:])
        let (bytes, response) = try await URLSession.shared.bytes(for: get)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return (status, []) }
        return try await withThrowingTaskGroup(of: [Double]?.self) { group in
            group.addTask {
                var values: [Double] = []
                for try await line in bytes.lines where line.hasPrefix("data:") && line.contains("notifications/progress") {
                    let json = try JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                    let params = json?["params"] as? [String: Any]
                    guard params?["progressToken"] as? String == token, let p = params?["progress"] as? Double else { continue }
                    values.append(p)
                    if p >= 100 { return values }
                }
                return values
            }
            group.addTask { try await whileOpen(); return nil }
            group.addTask { try await Task.sleep(for: timeout); return [] }
            var result: [Double] = []
            while let next = try await group.next() {
                guard let values = next else { continue }
                result = values
                break
            }
            group.cancelAll()
            bytes.task.cancel()
            return (status, result)
        }
    }
}

extension MCPBindingTests {
    @Test("A first GET that names another stream's event still opens the standalone stream, and progress arrives on it")
    func progressAfterStaleLastEventID() async throws {
        try await withEngine(freshConfig()) { port in
            var mcp = RawMCP(port: port)
            try await mcp.initialize()
            let stale = try #require(mcp.initializeEventID, "initialize's response carries a priming event id")
            let client = mcp
            let (status, values) = try await mcp.progress(token: "stale", lastEventID: stale) {
                try await Task.sleep(for: .milliseconds(100))
                _ = try await client.generate(token: "stale")
            }
            #expect(status == 200)
            #expect(!values.isEmpty && values == values.sorted() && values.last == 100, "progress \(values)")
        }
    }

    @Test("Progress sent before the client opens the standalone stream arrives once it opens, in order")
    func progressBeforeStreamOpens() async throws {
        try await withEngine(freshConfig()) { port in
            var mcp = RawMCP(port: port)
            try await mcp.initialize()
            let result = try await mcp.generate(token: "early")
            #expect(result.contains("\"result\""), "the call answered before any stream was open")
            let (status, values) = try await mcp.progress(token: "early")
            #expect(status == 200)
            #expect(!values.isEmpty && values == values.sorted() && values.last == 100, "progress \(values)")
        }
    }
}
