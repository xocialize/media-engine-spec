import Foundation
import HummingbirdWebSocket
import MESCore

/// The WebSocket channel (Base §11, `websocket` feature): one connection carries the events of any number of the
/// client's jobs. Client messages are `subscribe`, `unsubscribe`, `cancel` and `ping`; the engine sends events,
/// `pong`, and `error` frames for messages it can't act on.
enum EventSocket {
    struct ClientMessage: Decodable {
        var type: String
        var jobs: Jobs?
        var job: String?
    }

    /// `"*"` or a list of job ids.
    enum Jobs: Decodable {
        case all
        case ids([String])
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), s == "*" { self = .all; return }
            self = .ids(try c.decode([String].self))
        }
    }

    static let wildcard = "*"

    static func serve(inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter, client: String,
                      registry: JobRegistry, healthInterval: Duration) async {
        let (frames, sink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        let subscriptions = Subscriptions(sink: sink, registry: registry, client: client, healthInterval: healthInterval)
        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await frame in frames { try await outbound.write(.text(frame)) }
            }
            defer { group.cancelAll() }
            do {
                for try await message in inbound.messages(maxSize: 64 << 10) {
                    guard case .text(let text) = message else {
                        sink.yield(errorFrame(MESError(.invalidRequest, "Send JSON text messages.")))
                        continue
                    }
                    await handle(text, subscriptions: subscriptions, registry: registry, client: client, sink: sink)
                }
            } catch {}
            await subscriptions.cancelAll()
            sink.finish()
        }
    }

    static func handle(_ text: String, subscriptions: Subscriptions, registry: JobRegistry, client: String,
                       sink: AsyncStream<String>.Continuation) async {
        let message: ClientMessage
        do {
            message = try MESJSON.decoder.decode(ClientMessage.self, from: Data(text.utf8))
        } catch {
            sink.yield(errorFrame(MESError(.invalidRequest, "Malformed message: expected {\"type\": …}.")))
            return
        }
        switch message.type {
        case "ping":
            sink.yield(#"{"type":"pong"}"#)
        case "subscribe":
            switch message.jobs {
            case .all: await subscriptions.subscribeAll()
            case .ids(let ids):
                for id in ids {
                    do { try await subscriptions.subscribe(id) } catch let e as MESError { sink.yield(errorFrame(e)) } catch {}
                }
            case nil: sink.yield(errorFrame(MESError(.invalidRequest, "subscribe needs \"jobs\": [ids] or \"*\".")))
            }
        case "unsubscribe":
            switch message.jobs {
            case .all: await subscriptions.unsubscribe([wildcard])
            case .ids(let ids): await subscriptions.unsubscribe(ids)
            case nil: sink.yield(errorFrame(MESError(.invalidRequest, "unsubscribe needs \"jobs\".")))
            }
        case "cancel":
            guard let id = message.job else {
                sink.yield(errorFrame(MESError(.invalidRequest, "cancel needs \"job\".")))
                return
            }
            do { _ = try await registry.release(id, owner: client) } catch let e as MESError { sink.yield(errorFrame(e)) } catch {}
        default:
            sink.yield(errorFrame(MESError(.invalidRequest, "Unknown message type \(message.type).")))
        }
    }

    static func errorFrame(_ error: MESError) -> String {
        struct Frame: Encodable { var type = "error"; var error: MESError }
        return (try? String(decoding: MESJSON.encoder.encode(Frame(error: error)), as: UTF8.self))
            ?? #"{"type":"error","error":{"code":"engine_error","message":"error"}}"#
    }

    static func frame(_ event: Event) -> String? {
        (try? MESJSON.encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// One forwarding task per subscription: a job id, or `"*"` (the client's jobs and engine events).
    actor Subscriptions {
        private var tasks: [String: Task<Void, Never>] = [:]
        private let sink: AsyncStream<String>.Continuation
        private let registry: JobRegistry
        private let client: String
        private let healthInterval: Duration
        private var engineSeq = 0

        init(sink: AsyncStream<String>.Continuation, registry: JobRegistry, client: String, healthInterval: Duration) {
            self.sink = sink; self.registry = registry; self.client = client; self.healthInterval = healthInterval
        }

        func subscribe(_ id: String) async throws {
            guard tasks[id] == nil else { return }
            let events = try await registry.subscribe(id, owner: client, after: 0)
            let sink = self.sink
            tasks[id] = Task { [weak self] in
                for await event in events { if let f = EventSocket.frame(event) { sink.yield(f) } }
                await self?.ended(id)
            }
        }

        func subscribeAll() async {
            guard tasks[EventSocket.wildcard] == nil else { return }
            let events = await registry.subscribeAll(owner: client)
            let sink = self.sink
            let registry = self.registry
            let interval = healthInterval
            tasks[EventSocket.wildcard] = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in events { if let f = EventSocket.frame(event) { sink.yield(f) } }
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            guard let seq = await self?.nextEngineSeq() else { return }
                            let health = (try? JSONValue(encoding: await registry.health())) ?? .null
                            let event = Event(type: .engineHealth, job: nil, seq: seq, time: Date(), data: health)
                            if let f = EventSocket.frame(event) { sink.yield(f) }
                            try? await Task.sleep(for: interval)
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
        }

        func unsubscribe(_ ids: [String]) {
            for id in ids { tasks.removeValue(forKey: id)?.cancel() }
        }

        func cancelAll() {
            for task in tasks.values { task.cancel() }
            tasks = [:]
        }

        private func ended(_ id: String) { tasks[id] = nil }

        private func nextEngineSeq() -> Int {
            engineSeq += 1
            return engineSeq
        }
    }
}
