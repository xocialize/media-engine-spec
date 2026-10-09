import Foundation
import MESCore

/// The WebSocket channel (Base §11, `websocket` feature): one connection for the events of many jobs.
///
///     let socket = engine.eventSocket()
///     try await socket.subscribeAll()
///     for try await message in channel.messages { if case .event(let e) = message { … } }
public final class EventChannel: Sendable {
    public enum Message: Sendable, Equatable {
        case event(Event)
        case pong
        /// The engine couldn't act on a message (an unknown job, a refused cancel, …). The socket stays open.
        case error(MESError)
    }

    /// Everything the engine sends, until the socket closes.
    public let messages: AsyncThrowingStream<Message, any Error>
    private let task: URLSessionWebSocketTask
    private let reader: Task<Void, Never>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        let (stream, continuation) = AsyncThrowingStream<Message, any Error>.makeStream()
        messages = stream
        task.resume()
        reader = Task {
            while !Task.isCancelled {
                do {
                    guard case .string(let text) = try await task.receive() else { continue }
                    guard let message = Self.parse(text) else { continue }
                    continuation.yield(message)
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? nil : error)
                    return
                }
            }
            continuation.finish()
        }
    }

    deinit { close() }

    public func subscribe(_ jobs: [String]) async throws { try await send(["type": "subscribe", "jobs": .array(jobs.map { .string($0) })]) }
    /// The client's own jobs, and engine events such as `engine.health`.
    public func subscribeAll() async throws { try await send(["type": "subscribe", "jobs": "*"]) }
    public func unsubscribe(_ jobs: [String]) async throws { try await send(["type": "unsubscribe", "jobs": .array(jobs.map { .string($0) })]) }
    public func cancel(_ job: String) async throws { try await send(["type": "cancel", "job": .string(job)]) }
    public func ping() async throws { try await send(["type": "ping"]) }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        reader.cancel()
    }

    private func send(_ message: JSONValue) async throws {
        try await task.send(.string(String(decoding: try MESJSON.encoder.encode(message), as: UTF8.self)))
    }

    static func parse(_ text: String) -> Message? {
        let data = Data(text.utf8)
        guard let value = try? MESJSON.decoder.decode(JSONValue.self, from: data), let type = value["type"]?.stringValue else {
            return nil
        }
        switch type {
        case "pong": return .pong
        case "error": return (try? value["error"]?.decode(as: MESError.self)).map { .error($0) } ?? nil
        default: return (try? MESJSON.decoder.decode(Event.self, from: data)).map { .event($0) }
        }
    }
}

extension HTTPEngineConnection {
    /// Opens the engine's WebSocket channel, with the same pinning and token as this connection.
    public func eventChannel() -> EventChannel {
        var components = URLComponents(url: url("ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue(MESClientKit.baseVersion, forHTTPHeaderField: "MES-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return EventChannel(task: session.webSocketTask(with: request))
    }
}
