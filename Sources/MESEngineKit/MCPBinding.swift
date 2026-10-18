import CoreGraphics
import Foundation
import ImageIO
import MCP
import MESCore
import MESEngineCore
import UniformTypeIdentifiers

// The MCP binding (Base §15). This file imports MCP but not Hummingbird/HTTPTypes: both declare HTTPRequest and
// HTTPResponse, so here they are the SDK's. The session registry is adapted from ML[X] Image Server's (same author).

/// The MCP endpoint's reply in framework-neutral form, for the Hummingbird route.
struct MCPReply: Sendable {
    enum Body: Sendable {
        case empty
        case data(Data)
        case stream(AsyncThrowingStream<Data, any Error>)
    }
    var status: Int
    var headers: [String: String]
    var body: Body
}

private final class WeakServer: @unchecked Sendable {
    weak var server: Server?
    init(_ server: Server) { self.server = server }
}

/// One MCP `Server` + `StatefulHTTPServerTransport` per `Mcp-Session-Id`, each bound to the client that opened it.
actor MCPSessions {
    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let client: String
        var lastUsed: Date
    }

    private var sessions: [String: Session] = [:]
    let toolbox: MCPToolbox
    private let idleTimeout: TimeInterval = 3600

    init(toolbox: MCPToolbox) { self.toolbox = toolbox }

    func handle(method: String, headers: [String: String], body: Data?, path: String, client: String, clientHost: String?,
                baseURL: String) async -> MCPReply {
        let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
        let response = await handle(request, client: client, clientHost: clientHost, baseURL: baseURL)
        switch response {
        case .stream(let stream, let headers):
            return MCPReply(status: 200, headers: headers, body: .stream(stream))
        default:
            return MCPReply(status: response.statusCode, headers: response.headers, body: response.bodyData.map { .data($0) } ?? .empty)
        }
    }

    private func handle(_ request: HTTPRequest, client: String, clientHost: String?, baseURL: String) async -> HTTPResponse {
        expireIdle()
        if let id = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[id], session.client == client else {
                return .error(statusCode: 404, .invalidRequest("Unknown or expired MCP session; initialize again."))
            }
            session.lastUsed = Date()
            sessions[id] = session
            let response = await session.transport.handleRequest(request)
            if request.method == "DELETE" {
                sessions[id] = nil
                await session.server.stop()
            }
            return response
        }
        guard request.method == "POST" else {
            return .error(statusCode: 400, .invalidRequest("Missing Mcp-Session-Id; POST initialize first."))
        }
        do {
            let (server, transport) = try await makeSession(client: client, clientHost: clientHost, baseURL: baseURL)
            let response = await transport.handleRequest(request)
            if let id = response.headers[HTTPHeaderName.sessionID] {
                sessions[id] = Session(server: server, transport: transport, client: client, lastUsed: Date())
            } else {
                await server.stop()
            }
            return response
        } catch {
            return .error(statusCode: 500, .internalError("Could not start an MCP session: \(error)"))
        }
    }

    private func makeSession(client: String, clientHost: String?, baseURL: String) async throws -> (Server, StatefulHTTPServerTransport) {
        // Origins and auth already ran in the engine's middleware; the SDK checks the rest of the protocol.
        let transport = StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.disabled, AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(),
            ProtocolVersionValidator(), SessionValidator(),
        ]))
        let config = toolbox.config
        let server = Server(
            name: config.implementationName, version: config.implementationVersion, title: config.name,
            instructions: """
                A media engine following the Media Engine Specification (MES). Each tool is one operation \
                (image_generate, image_fill, …): pass inputs as data: URLs (or upload:<id>), and parameters by \
                their MES vocabulary names. A call waits up to wait_s seconds with progress, then returns the job; \
                continue with mes_get_job. Results name the model and its licence. Outputs are kept until \
                mes_confirm_job or until they expire.
                """,
            capabilities: .init(tools: .init(listChanged: false)))
        let toolbox = self.toolbox
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: await toolbox.tools()) }
        let notifier = WeakServer(server)
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(params, client: client, clientHost: clientHost, baseURL: baseURL) { notification in
                try? await notifier.server?.notify(notification)
            }
        }
        try await server.start(transport: transport)
        return (server, transport)
    }

    private func expireIdle() {
        let cutoff = Date().addingTimeInterval(-idleTimeout)
        for (id, session) in sessions where session.lastUsed < cutoff {
            sessions[id] = nil
            Task { await session.server.stop() }
        }
    }
}

/// Tools generated from descriptors: one per operation (`image.fill` → `image_fill`) plus the four helpers.
struct MCPToolbox: Sendable {
    typealias Notify = @Sendable (Message<ProgressNotification>) async -> Void
    let registry: JobRegistry
    let config: EngineConfiguration
    static let defaultWait = 50
    static let maxWait = 300

    static func toolName(_ operation: String) -> String { operation.replacingOccurrences(of: ".", with: "_") }

    // MARK: - Tools

    func tools() async -> [Tool] {
        let ops = await registry.operationsList.operations
        return ops.map(tool) + Self.helpers
    }

    func tool(_ d: Descriptor) -> Tool {
        var properties: [String: Value] = [:]
        var required: [String] = []
        for (name, schema) in d.params["properties"]?.objectValue ?? [:] {
            properties[name] = Self.value(Self.stripHints(schema))
        }
        for input in d.inputs {
            let one: Value = ["type": "string",
                              "description": .string("A \(input.kind.rawValue) as a data: URL (data:image/png;base64,…) or upload:<id>.")]
            switch input.kind {
            case .text:
                properties[input.name] = ["type": "string"]
            case .data:
                let vocab = d.profile == ImageProfile.id ? ImageProfile.vocabularySchema(input.name, operation: d.operation) : nil
                properties[input.name] = vocab.map(Self.value) ?? ["type": ["object", "array"]]
            default:
                properties[input.name] = (input.max ?? 1) > 1 ? ["type": "array", "items": one] : one
            }
            if input.required { required.append(input.name) }
        }
        let modelLines = d.models.map { Self.modelLine($0) }.joined(separator: "\n")
        let modelNotes = d.models.map { Self.modelLine($0, notes: true) }.joined(separator: "\n")
        properties["model"] = ["type": "string", "enum": .array(d.models.map { .string($0.id) }),
                               "description": .string("Omit to let the engine choose.\n\(modelLines)")]
        properties["wait_s"] = ["type": "integer", "minimum": 0, "maximum": .int(Self.maxWait), "default": .int(Self.defaultWait),
                                "description": "Seconds to wait for the result, with progress; then continue with mes_get_job."]
        properties["policy"] = ["type": "object", "additionalProperties": false,
                                "properties": ["license": ["enum": ["any", "commercial-use"]], "remote": ["enum": ["forbid", "allow"]]]]
        let schema: Value = ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
                             "additionalProperties": false]
        let readOnly = d.outputs.allSatisfy { $0.kind == .data }
        return Tool(name: Self.toolName(d.operation), title: d.title,
                    description: "\(d.title). \(d.summary ?? "")\nModels:\n\(modelNotes)",
                    inputSchema: schema, annotations: .init(title: d.title, readOnlyHint: readOnly ? true : nil, openWorldHint: false))
    }

    static let helpers: [Tool] = [
        Tool(name: "mes_list_operations", title: "List operations", description: "The operations this engine offers, with their models and licences.",
             inputSchema: ["type": "object", "properties": [:], "additionalProperties": false],
             annotations: .init(title: "List operations", readOnlyHint: true, openWorldHint: false)),
        Tool(name: "mes_get_job", title: "Get job", description: "A job's state and, when ready, its outputs. Waits up to wait_s for it to finish, with progress.",
             inputSchema: ["type": "object", "required": ["job_id"], "additionalProperties": false,
                           "properties": ["job_id": ["type": "string"], "wait_s": ["type": "integer", "minimum": 0, "maximum": .int(maxWait)]]],
             annotations: .init(title: "Get job", readOnlyHint: true, openWorldHint: false)),
        Tool(name: "mes_cancel_job", title: "Cancel job", description: "Cancels a job, or discards a finished job's outputs.",
             inputSchema: ["type": "object", "required": ["job_id"], "additionalProperties": false, "properties": ["job_id": ["type": "string"]]],
             annotations: .init(title: "Cancel job", destructiveHint: true, openWorldHint: false)),
        Tool(name: "mes_confirm_job", title: "Confirm job", description: "Says you have the outputs; the engine deletes them.",
             inputSchema: ["type": "object", "required": ["job_id"], "additionalProperties": false, "properties": ["job_id": ["type": "string"]]],
             annotations: .init(title: "Confirm job", destructiveHint: true, openWorldHint: false)),
    ]

    // MARK: - Calls

    func call(_ params: CallTool.Parameters, client: String, clientHost: String?, baseURL: String,
              notify: @escaping Notify) async -> CallTool.Result {
        let args = (params.arguments ?? [:]).mapValues(Self.json)
        do {
            switch params.name {
            case "mes_list_operations":
                let ops = await registry.operationsList.operations
                let lines = ops.map { "\(Self.toolName($0.operation)) — \($0.title) · models: \($0.models.map(\.id).joined(separator: ", "))" }
                return CallTool.Result(content: [.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil)],
                                       structuredContent: Optional(Self.value(try JSONValue(encoding: ops))))
            case "mes_get_job":
                let id = try Self.string(args, "job_id")
                let wait = min(Self.maxWait, max(0, args["wait_s"]?.intValue ?? 0))
                let job = wait > 0
                    ? try await waitWithProgress(id, owner: client, seconds: wait, token: params._meta?.progressToken, notify: notify)
                    : try await registry.job(id, owner: client)
                return await render(job, client: client, baseURL: baseURL)
            case "mes_cancel_job":
                return await render(try await registry.release(try Self.string(args, "job_id"), owner: client), client: client, baseURL: baseURL)
            case "mes_confirm_job":
                return await render(try await registry.confirm(try Self.string(args, "job_id"), owner: client), client: client, baseURL: baseURL)
            default:
                guard let descriptor = await registry.operationsList.operations.first(where: { Self.toolName($0.operation) == params.name }) else {
                    throw MESError(.unknownOperation, "No tool \(params.name).")
                }
                let request = try Self.jobRequest(descriptor, args)
                let job = try await registry.submit(request, owner: client, clientHost: clientHost, idempotencyKey: nil)
                let wait = min(Self.maxWait, max(0, args["wait_s"]?.intValue ?? Self.defaultWait))
                let done = try await waitWithProgress(job.id, owner: client, seconds: wait, token: params._meta?.progressToken, notify: notify)
                return await render(done, client: client, baseURL: baseURL)
            }
        } catch let error as MESError {
            return Self.errorResult(error)
        } catch {
            return Self.errorResult(MESError(.engineError, "\(error)"))
        }
    }

    /// MCP arguments → a JobRequest. Media inputs are data: URLs or `upload:<id>`.
    static func jobRequest(_ d: Descriptor, _ args: [String: JSONValue]) throws -> JobRequest {
        var inputs: [String: RequestInput] = [:]
        for spec in d.inputs {
            guard let value = args[spec.name] else { continue }
            switch spec.kind {
            case .text:
                guard let s = value.stringValue else { throw MESError(.inputInvalid, "\(spec.name) must be text.", param: spec.name) }
                inputs[spec.name] = .text(s)
            case .data:
                inputs[spec.name] = .one(.data(value))
            default:
                let strings = value.arrayValue?.compactMap(\.stringValue) ?? value.stringValue.map { [$0] } ?? []
                guard !strings.isEmpty else { throw MESError(.inputInvalid, "\(spec.name) must be a data: URL or upload:<id>.", param: spec.name) }
                let values = try strings.map { try mediaInput($0, name: spec.name) }
                inputs[spec.name] = values.count == 1 ? .one(values[0]) : .many(values)
            }
        }
        let paramNames = Set(d.params["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let params = args.filter { paramNames.contains($0.key) }
        let reserved: Set<String> = ["model", "wait_s", "policy"]
        let inputNames = Set(d.inputs.map(\.name))
        if let unknown = args.keys.first(where: { !paramNames.contains($0) && !reserved.contains($0) && !inputNames.contains($0) }) {
            throw MESError(.unsupportedParameter, "\(toolName(d.operation)) has no argument '\(unknown)'.", param: unknown)
        }
        let policy = try args["policy"].map { try $0.decode(as: Policy.self) }
        return JobRequest(operation: d.operation, inputs: inputs, params: params.isEmpty ? nil : params,
                          model: args["model"]?.stringValue, policy: policy)
    }

    static func mediaInput(_ s: String, name: String) throws -> InputValue {
        if s.hasPrefix("upload:") { return .upload(String(s.dropFirst("upload:".count))) }
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ","), s[..<comma].hasSuffix(";base64") else {
            throw MESError(.inputInvalid, "\(name): use a data: URL (data:<type>;base64,…) or upload:<id>.", param: name)
        }
        let mediaType = String(s[s.index(s.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count))
        guard let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else {
            throw MESError(.inputInvalid, "\(name): the data: URL isn't valid base64.", param: name)
        }
        return .inline(mediaType: mediaType, data: data)
    }

    /// Waits for the job to finish or `seconds` to pass, sending `notifications/progress` (0–100) on the way.
    func waitWithProgress(_ id: String, owner: String, seconds: Int, token: ProgressToken?, notify: @escaping Notify) async throws -> Job {
        let stream = try await registry.subscribe(id, owner: owner, after: 0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var sent = 0.0
                for await event in stream {
                    var progress = sent
                    var message: String?
                    switch event.type {
                    case .state:
                        let state = event.data["state"]?.stringValue ?? ""
                        progress = ["received": 1, "fetching": 3, "waiting": 5, "running": 10, "holding": 100, "purged": 100][state] ?? sent
                        message = state
                    case .progress:
                        progress = 10 + 85 * (event.data["fraction"]?.numberValue ?? 0)
                    case .outputReady, .ended:
                        progress = 100
                    default:
                        break
                    }
                    if let token, progress > sent {
                        sent = progress
                        await notify(ProgressNotification.message(.init(progressToken: token, progress: progress, total: 100, message: message)))
                    }
                    if event.type == .outputReady || event.type == .ended { return }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
        return try await registry.job(id, owner: owner)
    }

    // MARK: - Results

    func render(_ job: Job, client: String, baseURL: String) async -> CallTool.Result {
        var lines = ["\(job.operation) · \(job.id) · \(job.state.rawValue)\(job.outcome.map { " (\($0.rawValue))" } ?? "")"]
        if let model = job.plan?.model ?? job.result?.provenance.model {
            lines.append("Model: \(model.id) · \(model.license.spdx) · commercial use \(Self.commercial(model.license.commercialUse))"
                + (model.license.notice.map { " · \($0)" } ?? ""))
        }
        for w in job.warnings { lines.append("Warning [\(w.code)]: \(w.message)") }
        var content: [Tool.Content] = []
        if let result = job.result {
            for output in result.outputs {
                let url = baseURL + output.href
                let size = output.width.map { w in " \(w)×\(output.height ?? 0)" } ?? ""
                lines.append("Output \(output.index) \(output.name): \(output.mediaType)\(size) · \(url)")
                if let value = output.value, let text = try? String(decoding: MESJSON.encoder.encode(value), as: UTF8.self) {
                    lines.append("\(output.name): \(text)")
                }
                if output.kind == .image || output.kind == .mask,
                   let (file, _) = try? await registry.output(job.id, index: output.index, owner: client),
                   let preview = Self.preview(file, mediaType: output.mediaType) {
                    content.append(.image(data: preview.data.base64EncodedString(), mimeType: preview.mediaType, annotations: nil, _meta: nil))
                }
                content.append(.resourceLink(uri: url, name: "\(job.id)-\(output.index)", mimeType: output.mediaType))
            }
            if let expires = job.retention.outputsExpireAt {
                lines.append("Outputs are kept until \(MESJSON.timestamp(expires)) or mes_confirm_job.")
            }
        } else if job.state != .purged {
            lines.append("Still \(job.state.rawValue)\(job.progress?.fraction.map { String(format: " (%.0f%%)", $0 * 100) } ?? ""); continue with mes_get_job.")
        }
        if let error = job.error { lines.append("Error [\(error.code)]: \(error.message)") }
        content.insert(.text(text: lines.joined(separator: "\n"), annotations: nil, _meta: nil), at: 0)
        let structured = (try? JSONValue(encoding: job)).map(Self.value)
        return CallTool.Result(content: content, structuredContent: structured, isError: job.outcome == .failed ? true : nil)
    }

    /// The output itself if it's a PNG/JPEG of at most 1 MB, else a JPEG preview at most 1024 px.
    static func preview(_ url: URL, mediaType: String) -> (data: Data, mediaType: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.count <= 1 << 20, ["image/png", "image/jpeg"].contains(mediaType) { return (data, mediaType) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, "image/jpeg")
    }

    static func errorResult(_ error: MESError) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "[\(error.code)] \(error.message)", annotations: nil, _meta: nil)],
                        structuredContent: ["error": ["code": .string(error.code), "message": .string(error.message)]] as Value?, isError: true)
    }

    // MARK: - Conversions

    static func value(_ json: JSONValue) -> Value {
        (try? MESJSON.decoder.decode(Value.self, from: MESJSON.encoder.encode(json))) ?? .null
    }

    static func json(_ value: Value) -> JSONValue {
        (try? MESJSON.decoder.decode(JSONValue.self, from: MESJSON.encoder.encode(value))) ?? .null
    }

    static func stripHints(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o): return .object(o.filter { !$0.key.hasPrefix("x-") }.mapValues(stripHints))
        case .array(let a): return .array(a.map(stripHints))
        default: return v
        }
    }

    static func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let s = args[key]?.stringValue else { throw MESError(.invalidRequest, "\(key) is required.", param: key) }
        return s
    }

    /// One model offer on one line (Base §15): id, title, licence, default, tiers; with `notes`, its `license.notice` and
    /// `notes` too. The tool description carries those; the `model` parameter keeps the short line, so each appears once.
    static func modelLine(_ m: ModelOffer, notes: Bool = false) -> String {
        var line = "\(m.id): \(m.title) · \(m.license.spdx) · commercial use \(commercial(m.license.commercialUse))"
            + (m.isDefault == true ? " · default" : "") + " · tiers \(m.qualityTiers.map(\.rawValue).joined(separator: "/"))"
        guard notes else { return line }
        if let notice = oneLine(m.license.notice) { line += " · Licence: \(notice)" }
        if let text = oneLine(m.notes) { line += " · Notes: \(text)" }
        return line
    }

    /// Text folded onto one line, or nil when empty.
    static func oneLine(_ text: String?) -> String? {
        guard let words = text?.split(whereSeparator: \.isWhitespace), !words.isEmpty else { return nil }
        return words.joined(separator: " ")
    }

    static func commercial(_ c: CommercialUse) -> String { switch c { case .yes: "yes"; case .no: "no"; case .unknown: "unknown" } }
}
