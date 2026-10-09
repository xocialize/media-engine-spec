import Foundation
import MESEngineKit
import MockEngineCore

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so the listening line shows up when piped

// mes-mock-engine — the MES Image-profile mock engine (open mode, loopback only).
//
//   mes-mock-engine [--port 17600] [--spool <dir>] [--delay-ms 0] [--steps 4] [--ttl 3600]

var port = 17600
var spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-mock-engine-spool")
var delayMs = 0
var steps = 4
var ttl = 3600
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--port": port = Int(args.next() ?? "") ?? port
    case "--spool": spool = URL(fileURLWithPath: args.next() ?? spool.path)
    case "--delay-ms": delayMs = Int(args.next() ?? "") ?? 0
    case "--steps": steps = Int(args.next() ?? "") ?? 4
    case "--ttl": ttl = Int(args.next() ?? "") ?? ttl
    case "-h", "--help":
        print("mes-mock-engine [--port 17600] [--spool <dir>] [--delay-ms 0] [--steps 4] [--ttl 3600]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(arg)\n".utf8))
        exit(2)
    }
}

var config = EngineConfiguration(id: "eng_mock", name: "MES Mock Image Engine", implementationName: "mes-mock-engine",
                                 implementationVersion: "0.1.0", spoolDirectory: spool)
config.port = port
config.outputsTTLSeconds = ttl
let basePath = config.basePath
let server = MESEngineServer(engine: MockImageEngine(stepDelay: .milliseconds(delayMs), steps: steps), configuration: config)
try await server.run { port in
    print("mes-mock-engine listening on http://127.0.0.1:\(port)\(basePath) (open mode, loopback only)")
}
