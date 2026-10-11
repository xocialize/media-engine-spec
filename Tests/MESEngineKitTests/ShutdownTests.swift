import Foundation
import Hummingbird
@testable import MESCore
@testable import MESEngineKit
import ServiceLifecycle
import Testing
import UnixSignals

// Signal handling (`EngineConfiguration.handlesShutdownSignals`): a standalone engine stops on SIGTERM within its grace
// period even with a request in flight, and an embedded one traps nothing, so SIGTERM ends the process hosting it.
@Suite("Shutdown signals")
struct ShutdownTests {
    @Test func signalHandlingFollowsTheConfiguration() {
        let app = Application(router: Router())
        let standalone = MESEngineServer.serviceGroupConfiguration(app, freshConfig(), logger: app.logger)
        #expect(standalone.gracefulShutdownSignals == [.sigterm, .sigint])
        #expect(standalone.cancellationSignals.isEmpty)
        #expect(standalone.maximumGracefulShutdownDuration == .seconds(5))

        let embedded = MESEngineServer.serviceGroupConfiguration(app, freshConfig { $0.handlesShutdownSignals = false },
                                                                 logger: app.logger)
        #expect(embedded.gracefulShutdownSignals.isEmpty)
        #expect(embedded.cancellationSignals.isEmpty)
    }

    /// `mes-mock-engine`, sent SIGTERM while an event stream is open. Before 0.1.2 it waited for the stream (as long as
    /// the job ran) and ignored every later signal.
    @Test func sigtermEndsAStandaloneEngineWithAStreamOpen() async throws {
        // `swift test` builds every product beside the test bundle.
        let binary = Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mes-mock-engine")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "mes-mock-engine isn't built")
        let port = try freeLoopbackPort()
        let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-test-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--port", "\(port)", "--spool", spool.path, "--no-advertise", "--delay-ms", "1000", "--steps", "120"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

        let health = URL(string: "http://127.0.0.1:\(port)/mes/v0/health")!
        var up = false
        for _ in 0..<100 where !up {
            up = (try? await URLSession.shared.data(from: health)) != nil
            if !up { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(up, "mes-mock-engine didn't start")

        let job = try await submit(port: port, JobRequest(operation: "image.generate", inputs: ["prompt": .text("a fox")]))
        let events = URL(string: "http://127.0.0.1:\(port)/mes/v0/jobs/\(job.id)/events")!
        let (bytes, _) = try await URLSession.shared.bytes(from: events)
        var lines = bytes.lines.makeAsyncIterator()
        #expect(try await lines.next() != nil)   // the stream is open

        let start = ContinuousClock.now
        kill(process.processIdentifier, SIGTERM)
        while process.isRunning, ContinuousClock.now - start < .seconds(15) { try await Task.sleep(for: .milliseconds(100)) }
        let elapsed = ContinuousClock.now - start
        try #require(!process.isRunning, "still running \(elapsed) after SIGTERM")
        #expect(process.terminationReason == .exit && process.terminationStatus == 0)
        #expect(elapsed < .seconds(9))   // the 5 s grace period, then the stream is cancelled
    }
}

private final class TestBundle {}

func freeLoopbackPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
    return Int(UInt16(bigEndian: address.sin_port))
}
