import Foundation
import MCP
@testable import MESCore
@testable import MESEngineKit
@testable import MockEngineCore
import Testing

// The MCP binding (Base §15) through the swift-sdk client, and the WebSocket channel (Base §11) through
// URLSessionWebSocketTask, both against a live engine.

actor ProgressLog {
    private(set) var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}

func mcpClient(port: Int, progress: ProgressLog? = nil) async throws -> Client {
    let client = Client(name: "mes-tests", version: "0.1.0")
    if let progress {
        await client.onNotification(ProgressNotification.self) { message in await progress.add(message.params.progress) }
    }
    // streaming: the SDK's server sends notifications (progress) on the standalone GET stream, as Claude Code opens it.
    let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mes/v0/mcp")!, streaming: true)
    _ = try await client.connect(transport: transport)
    return client
}

/// Calls a tool and returns the full result (content, structuredContent, isError).
func callTool(_ client: Client, _ name: String, _ arguments: [String: Value], progressToken: String? = nil) async throws
    -> CallTool.Result {
    let meta = progressToken.map { Metadata(progressToken: .string($0)) }
    let context: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: arguments, meta: meta)
    return try await context.value
}

func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(separator: "\n")
}

func job(_ result: CallTool.Result) throws -> Job {
    let value = try #require(result.structuredContent)
    return try MESJSON.decoder.decode(Job.self, from: try MESJSON.encoder.encode(value))
}

func dataURL(_ data: Data, _ type: String = "image/png") -> Value { .string("data:\(type);base64,\(data.base64EncodedString())") }

func containsKey(_ value: Value, prefix: String) -> Bool {
    switch value {
    case .object(let o): o.keys.contains { $0.hasPrefix(prefix) } || o.values.contains { containsKey($0, prefix: prefix) }
    case .array(let a): a.contains { containsKey($0, prefix: prefix) }
    default: false
    }
}

@Suite("MCP binding (Base §15)", .serialized)
struct MCPBindingTests {
    @Test("Tools come from descriptors; generate returns a summary, a preview, a link and the job, with progress")
    func generate() async throws {
        try await withEngine(freshConfig()) { port in
            let progress = ProgressLog()
            let client = try await mcpClient(port: port, progress: progress)
            let (tools, _) = try await client.listTools()
            let names = Set(tools.map(\.name))
            #expect(names.isSuperset(of: ["image_generate", "image_fill", "image_upscale", "mes_list_operations", "mes_get_job",
                                          "mes_cancel_job", "mes_confirm_job"]))
            #expect(tools.count == 15 + 5)       // the operations and five helpers, mes_list_voices among them
            let generate = try #require(tools.first { $0.name == "image_generate" })
            let props = generate.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
            #expect(props["prompt"] != nil && props["wait_s"] != nil && props["model"] != nil && props["size"] != nil)
            #expect(generate.inputSchema.objectValue?["required"] == ["prompt"])
            #expect(!containsKey(generate.inputSchema, prefix: "x-"), "UI hints are stripped from tool schemas")
            #expect(generate.description?.contains("mock-research") == true, "the model list names each licence")
            let research = try #require(generate.description?.split(separator: "\n").first { $0.hasPrefix("mock-research:") })
            #expect(research.hasSuffix("· Licence: A stand-in for research-only weights. · Notes: Describe the whole scene. "
                                       + "Put text to render in quotes."), "an offer's notice and notes follow its line (§15)")
            let modelParam = props["model"]?.objectValue?["description"]?.stringValue ?? ""
            #expect(modelParam.contains("mock-research:") && !modelParam.contains("Notes:"), "the model parameter keeps the short line")

            let result = try await callTool(client, "image_generate",
                                            ["prompt": "a red fox", "size": ["width": 32, "height": 24], "seed": 7],
                                            progressToken: "gen-1")
            #expect(result.isError != true, "\(text(result))")
            let summary = text(result)
            #expect(summary.contains("Model: mock · Apache-2.0 · commercial use yes"), "\(summary)")
            #expect(summary.contains("mes_confirm_job"))
            let images = result.content.compactMap { if case .image(let d, let m, _, _) = $0 { (d, m) } else { nil } }
            #expect(images.count == 1 && images.first?.1 == "image/png")
            let links = result.content.compactMap { if case .resourceLink(let uri, _, _, _, _, _) = $0 { uri } else { nil } }
            let link = try #require(links.first)
            #expect(link.hasPrefix("http://127.0.0.1:\(port)/mes/v0/jobs/"))
            let (bytes, response) = try await URLSession.shared.data(from: URL(string: link)!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(bytes.base64EncodedString() == images.first?.0, "the preview is the output itself when small")
            let j = try job(result)
            #expect(j.state == .holding && j.outcome == .succeeded && j.result?.outputs.first?.width == 32)
            try await Task.sleep(for: .milliseconds(200))
            let seen = await progress.values
            #expect(!seen.isEmpty && seen == seen.sorted() && seen.last == 100, "progress \(seen)")

            let confirmed = try job(try await callTool(client, "mes_confirm_job", ["job_id": .string(j.id)]))
            #expect(confirmed.state == .purged)
            await client.disconnect()
        }
    }

    @Test("A model line folds its notice and notes onto one line and leaves out what's absent")
    func modelLine() {
        let license = License(spdx: "LicenseRef-X", commercialUse: .no, notice: "No commercial\nuse.  ")
        var offer = ModelOffer(id: "x", title: "X", license: license, qualityTiers: [.best], notes: "  Quote\ttext. ")
        #expect(MCPToolbox.modelLine(offer, notes: true)
                == "x: X · LicenseRef-X · commercial use no · tiers best · Licence: No commercial use. · Notes: Quote text.")
        #expect(MCPToolbox.modelLine(offer) == "x: X · LicenseRef-X · commercial use no · tiers best")
        offer.notes = " \n"; offer.license.notice = nil
        #expect(MCPToolbox.modelLine(offer, notes: true) == "x: X · LicenseRef-X · commercial use no · tiers best")
    }

    @Test("Fill with data: URLs; bad arguments are tool errors, not protocol errors")
    func fillAndErrors() async throws {
        try await withEngine(freshConfig()) { port in
            let client = try await mcpClient(port: port)
            let image = try pngData(width: 16, height: 16) { x, _ in (UInt8(x * 16), 0, 0, 255) }
            let mask = try greyPNG(width: 16, height: 16) { x, _ in x < 8 ? 0 : 255 }
            let fill = try await callTool(client, "image_fill", ["image": dataURL(image), "mask": dataURL(mask), "prompt": "sky"])
            #expect(fill.isError != true, "\(text(fill))")
            #expect(try job(fill).outcome == .succeeded)

            let badURL = try await callTool(client, "image_fill", ["image": "https://example.com/a.png", "mask": dataURL(mask)])
            #expect(badURL.isError == true && text(badURL).contains("input_invalid"))
            let unknown = try await callTool(client, "image_generate", ["prompt": "x", "bogus": 1])
            #expect(unknown.isError == true && text(unknown).contains("unsupported_parameter"))
            let noTool = try await callTool(client, "image_nope", [:])
            #expect(noTool.isError == true && text(noTool).contains("unknown_operation"))
            let research = try await callTool(client, "image_generate", ["prompt": "x", "model": "mock-research",
                                                                         "policy": ["license": "commercial-use"]])
            #expect(research.isError == true && text(research).contains("policy_unmet"), "\(text(research))")
            let missing = try await callTool(client, "mes_get_job", ["job_id": "job_nope"])
            #expect(missing.isError == true && text(missing).contains("not_found"))
            await client.disconnect()
        }
    }

    @Test("A job that outlasts wait_s comes back running; mes_get_job continues it, mes_cancel_job cancels another")
    func longJobs() async throws {
        try await withEngine(freshConfig(), engine: MockImageEngine(stepDelay: .milliseconds(300), steps: 5)) { port in
            let client = try await mcpClient(port: port)
            let early = try await callTool(client, "image_generate", ["prompt": "slow", "size": ["width": 16, "height": 16],
                                                                      "wait_s": 0])
            let first = try job(early)
            #expect(first.outcome == nil && text(early).contains("continue with mes_get_job"), "\(text(early))")
            let done = try job(try await callTool(client, "mes_get_job", ["job_id": .string(first.id), "wait_s": 10]))
            #expect(done.state == .holding)

            let second = try job(try await callTool(client, "image_generate", ["prompt": "cancel me", "wait_s": 0]))
            let cancelled = try job(try await callTool(client, "mes_cancel_job", ["job_id": .string(second.id)]))
            #expect(cancelled.outcome == .cancelled)
            await client.disconnect()
        }
    }
}

// MARK: - WebSocket

/// A JSON-message view of URLSessionWebSocketTask.
struct Socket {
    let task: URLSessionWebSocketTask

    init(_ url: String, session: URLSession = .shared, headers: [String: String] = [:]) {
        var request = URLRequest(url: URL(string: url)!)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ json: String) async throws { try await task.send(.string(json)) }

    func receive() async throws -> [String: Any] {
        guard case .string(let s) = try await task.receive() else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
    }

    /// Reads until a message matches, returning everything read.
    func receive(until match: ([String: Any]) -> Bool, limit: Int = 100) async throws -> [[String: Any]] {
        var seen: [[String: Any]] = []
        for _ in 0..<limit {
            let m = try await receive()
            seen.append(m)
            if match(m) { return seen }
        }
        return seen
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

func submit(port: Int, _ request: JobRequest) async throws -> Job {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mes/v0/jobs")!)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try MESJSON.encoder.encode(request)
    let (data, _) = try await URLSession.shared.data(for: r)
    return try MESJSON.decoder.decode(Job.self, from: data)
}

@Suite("WebSocket channel (Base §11)", .serialized)
struct WebSocketTests {
    @Test("subscribe \"*\": engine health, then every event of the client's jobs; ping/pong; error frames")
    func wildcard() async throws {
        try await withEngine(freshConfig()) { port in
            let ws = Socket("ws://127.0.0.1:\(port)/mes/v0/ws")
            defer { ws.close() }
            try await ws.send(#"{"type":"ping"}"#)
            #expect(try await ws.receive()["type"] as? String == "pong")

            try await ws.send(#"{"type":"subscribe","jobs":"*"}"#)
            let health = try await ws.receive()
            #expect(health["type"] as? String == "engine.health" && health["job"] == nil)
            #expect((health["data"] as? [String: Any])?["status"] as? String == "ok")

            let j = try await submit(port: port, JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")],
                                                             params: ["size": ["width": 16, "height": 16]]))
            let events = try await ws.receive(until: { $0["type"] as? String == "job.output_ready" })
            let jobEvents = events.filter { $0["job"] as? String == j.id }
            #expect(jobEvents.last?["type"] as? String == "job.output_ready")
            let seqs = jobEvents.compactMap { $0["seq"] as? Int }
            #expect(seqs == seqs.sorted() && !seqs.isEmpty)
            let types = Set(jobEvents.compactMap { $0["type"] as? String })
            #expect(types.isSuperset(of: ["job.state", "job.plan", "job.progress"]), "\(types)")

            try await ws.send(#"{"type":"subscribe","jobs":["job_nope"]}"#)
            let notFound = try await ws.receive(until: { $0["type"] as? String == "error" }).last
            #expect((notFound?["error"] as? [String: Any])?["code"] as? String == "not_found")
            try await ws.send("not json")
            let malformed = try await ws.receive(until: { $0["type"] as? String == "error" }).last
            #expect((malformed?["error"] as? [String: Any])?["code"] as? String == "invalid_request")
        }
    }

    @Test("Subscribing to a job replays its events; cancel over the socket ends it cancelled")
    func cancelOverSocket() async throws {
        try await withEngine(freshConfig(), engine: MockImageEngine(stepDelay: .milliseconds(300), steps: 8)) { port in
            let ws = Socket("ws://127.0.0.1:\(port)/mes/v0/ws")
            defer { ws.close() }
            let j = try await submit(port: port, JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")]))
            try await ws.send(#"{"type":"subscribe","jobs":["\#(j.id)"]}"#)
            let first = try await ws.receive()
            #expect(first["job"] as? String == j.id && first["seq"] as? Int == 1, "replay starts at the first event")
            try await ws.send(#"{"type":"cancel","job":"\#(j.id)"}"#)
            let events = try await ws.receive(until: { $0["type"] as? String == "job.ended" })
            #expect((events.last?["data"] as? [String: Any])?["outcome"] as? String == "cancelled")
        }
    }

    @Test("A browser origin that isn't allowed can't open the socket")
    func originRefused() async throws {
        try await withEngine(freshConfig()) { port in
            let ws = Socket("ws://127.0.0.1:\(port)/mes/v0/ws", headers: ["Origin": "https://evil.example"])
            var refused = false
            do { _ = try await ws.receive() } catch { refused = true }
            #expect(refused)
        }
    }

    @Test("Paired mode: the socket needs a token; with one it carries only that client's jobs")
    func paired() async throws {
        let op = Operator()
        try await withEngine(pairedConfig(operator: op)) { port in
            var a = TLSClient(port: port)
            a.token = try await pair(a, id: "cli_a", name: "A").approved?.token
            let token = try #require(a.token)

            let anonymous = Socket("wss://localhost:\(port)/mes/v0/ws", session: a.session)
            var refused = false
            do { _ = try await anonymous.receive() } catch { refused = true }
            #expect(refused, "no token, no socket")

            let ws = Socket("wss://localhost:\(port)/mes/v0/ws", session: a.session, headers: ["Authorization": "Bearer \(token)"])
            defer { ws.close() }
            try await ws.send(#"{"type":"ping"}"#)
            #expect(try await ws.receive()["type"] as? String == "pong")

            var b = TLSClient(port: port)
            b.token = try await pair(b, id: "cli_b", name: "B").approved?.token
            let job = JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")], params: ["size": ["width": 16, "height": 16]])
            let (_, body) = try await b.send("POST", "/jobs", json: try MESJSON.encoder.encode(job))
            let bJob = try MESJSON.decoder.decode(Job.self, from: body)
            try await ws.send(#"{"type":"subscribe","jobs":["\#(bJob.id)"]}"#)
            let reply = try await ws.receive()
            #expect(reply["type"] as? String == "error", "another client's job is not found")
        }
    }
}

// MARK: - Connection hygiene

/// Connects, writes `raw`, and returns the seconds until the server closes the connection, or nil if it is still
/// open after `limit` seconds.
func secondsUntilClosed(port: Int, sending raw: String, limit: Int) -> Double? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return nil }
    var tv = timeval(tv_sec: limit, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let start = Date()
    _ = raw.withCString { write(fd, $0, strlen($0)) }
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n == 0 { return Date().timeIntervalSince(start) }
        if n < 0 { return errno == EAGAIN || errno == EWOULDBLOCK ? nil : Date().timeIntervalSince(start) }
    }
}

@Suite("Connection hygiene", .serialized)
struct ConnectionTests {
    @Test("A keep-alive connection idle after its response is closed; a long poll past the timeout is not")
    func idleTimeout() async throws {
        let config = freshConfig { $0.idleTimeout = .seconds(1) }
        try await withEngine(config, engine: MockImageEngine(stepDelay: .milliseconds(400), steps: 8)) { port in
            let raw = "GET /mes/v0/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            let closed = await Task.detached { secondsUntilClosed(port: port, sending: raw, limit: 5) }.value
            #expect(closed != nil && closed! < 3, "closed after \(closed.map { "\($0)s" } ?? "never")")

            let j = try await submit(port: port, JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")]))
            let start = Date()
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/mes/v0/jobs/\(j.id)?wait=3")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty)
            let polled = try MESJSON.decoder.decode(Job.self, from: data)
            #expect(polled.state != .received || Date().timeIntervalSince(start) < 1, "a wait in flight isn't idle")
        }
    }

    @Test("Connections that never complete a first request head are closed by the deadline (AB-T-0211); upgraded sockets and long polls aren't")
    func headDeadline() async throws {
        let config = freshConfig { $0.requestHeadTimeout = .seconds(1) }
        try await withEngine(config, engine: MockImageEngine(stepDelay: .milliseconds(300), steps: 8)) { port in
            let cases = [
                ("silent", ""),
                ("half a head", "GET /mes/v0/health HTTP/1.1\r\nHost: 127.0.0.1\r\n"),
                ("a malformed head with a body", "POST /mes/v0/jobs HTTP/1.1\r\nHost: 127.0.0.1\r\n folded:header\r\nContent-Length: 2\r\n\r\n{}"),
            ]
            for (name, raw) in cases {
                let closed = await Task.detached { secondsUntilClosed(port: port, sending: raw, limit: 5) }.value
                #expect(closed != nil && closed! < 3, "\(name): closed after \(closed.map { "\($0)s" } ?? "never")")
            }

            let ws = Socket("ws://127.0.0.1:\(port)/mes/v0/ws")
            defer { ws.close() }
            try await ws.send(#"{"type":"ping"}"#)
            #expect(try await ws.receive()["type"] as? String == "pong")
            try await Task.sleep(for: .milliseconds(1600))
            try await ws.send(#"{"type":"ping"}"#)
            #expect(try await ws.receive()["type"] as? String == "pong", "an upgraded socket outlives the head deadline")

            let j = try await submit(port: port, JobRequest(operation: "image.generate", inputs: ["prompt": .text("x")]))
            let start = Date()
            let url = URL(string: "http://127.0.0.1:\(port)/mes/v0/jobs/\(j.id)?wait=3")!
            var polled = try MESJSON.decoder.decode(Job.self, from: try await URLSession.shared.data(from: url).0)
            while polled.state != .holding, Date().timeIntervalSince(start) < 10 {
                polled = try MESJSON.decoder.decode(Job.self, from: try await URLSession.shared.data(from: url).0)
            }
            #expect(polled.state == .holding && Date().timeIntervalSince(start) > 1.5, "long polls past the deadline complete")
        }
    }

    @Test("Paired mode: a connection that never starts its TLS handshake is closed by the deadline")
    func headDeadlineTLS() async throws {
        var config = pairedConfig(operator: Operator())
        config.requestHeadTimeout = .seconds(1)
        try await withEngine(config) { port in
            let closed = await Task.detached { secondsUntilClosed(port: port, sending: "", limit: 5) }.value
            #expect(closed != nil && closed! < 3, "closed after \(closed.map { "\($0)s" } ?? "never")")
            let client = TLSClient(port: port)
            let (status, _) = try await client.send("GET", "/engine")
            #expect(status == 200, "a real client still connects")
        }
    }
}
