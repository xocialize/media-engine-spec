import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOSSL
import NIOWebSocket

// A deadline for a connection's first request head (AB-T-0211). hummingbird-websocket arms its idle timer only
// after deciding between HTTP and a WebSocket upgrade, which needs a complete request head. Until then nothing closes
// a connection: not a client that opens one and sends nothing (or trickles bytes, slowloris), not a malformed head
// that stops the parser, not a TLS handshake that never finishes. Paired engines face the LAN, so each connection
// must earn its keep: decide within the deadline or be closed.

/// Wraps a child channel with a ``HeadDeadlineHandler`` (the same shape as HummingbirdTLS's `TLSChannel`).
struct HeadDeadlineChannel<BaseChannel: ServerChildChannel>: ServerChildChannel {
    typealias Value = BaseChannel.Value
    let baseChannel: BaseChannel
    let deadline: TimeAmount

    func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(HeadDeadlineHandler(deadline: deadline), position: .first)
        }.flatMap {
            baseChannel.setup(channel: channel, logger: logger)
        }
    }

    func handle(value: Value, logger: Logger) async {
        await baseChannel.handle(value: value, logger: logger)
    }
}

extension HeadDeadlineChannel: HTTPChannelHandler where BaseChannel: HTTPChannelHandler {
    var responder: HTTPChannelHandler.Responder { baseChannel.responder }
}

extension ServerChildChannel {
    func withHeadDeadline(_ deadline: TimeAmount) -> any ServerChildChannel {
        HeadDeadlineChannel(baseChannel: self, deadline: deadline)
    }
}

extension HTTPServerBuilder {
    /// HTTP/1.1 with WebSocket upgrades through `router`, optionally over TLS, behind a first-request-head deadline.
    /// Composed from the public channel types: Hummingbird keeps `buildChildChannel`, which wrapping an existing
    /// builder would need, package-internal.
    static func mesEngine<Router: HTTPResponderBuilder>(router: Router, idleTimeout: TimeAmount, tls: TLSConfiguration?,
                                                       headDeadline: TimeAmount) -> HTTPServerBuilder
        where Router.Responder.Context: WebSocketRequestContext {
        let webSocketResponder = router.buildResponder()
        return .init { responder in
            let http = HTTP1WebSocketUpgradeChannel(
                responder: responder, webSocketResponder: webSocketResponder,
                configuration: .init(http1: .init(idleTimeout: idleTimeout), ws: .init()))
            guard let tls else { return http.withHeadDeadline(headDeadline) }
            return try TLSChannel(http, tlsConfiguration: tls).withHeadDeadline(headDeadline)
        }
    }
}

/// Closes the channel `deadline` after it opens unless, by then, the pipeline has decided: Hummingbird's
/// `HTTPConnectionStateHandler` is present (a request head was parsed; its own idle timeout takes over from here) or
/// NIO's `WebSocketFrameEncoder` is (the connection upgraded; WebSocket pings take over).
final class HeadDeadlineHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    let deadline: TimeAmount
    private var timer: Scheduled<Void>?

    init(deadline: TimeAmount) { self.deadline = deadline }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { arm(context.channel) }
    }

    func channelActive(context: ChannelHandlerContext) {
        arm(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { timer?.cancel() }

    private func arm(_ channel: any Channel) {
        guard timer == nil else { return }
        timer = channel.eventLoop.scheduleTask(in: deadline) {
            let pipeline = channel.pipeline.syncOperations
            let decided = (try? pipeline.handler(type: HTTPConnectionStateHandler.self)) != nil
                || (try? pipeline.handler(type: WebSocketFrameEncoder.self)) != nil
            if !decided { channel.close(promise: nil) }
        }
    }
}

extension TimeAmount {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self = .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }
}
