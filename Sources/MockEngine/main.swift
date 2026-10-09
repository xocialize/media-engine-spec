import Foundation
import MESEngineKit
import MockEngineCore

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so the listening line shows up when piped

// mes-mock-engine — the MES Image-profile mock engine.
//
//   mes-mock-engine [--port 17600] [--spool <dir>] [--state <dir>] [--delay-ms 0] [--steps 4] [--ttl 3600]
//                   [--paired [--host 0.0.0.0] [--approve prompt|auto]] [--no-advertise]
//
// Open mode (default): HTTP on 127.0.0.1, loopback clients only. Paired mode: TLS with a self-signed certificate;
// clients pair with a 6-digit code confirmed here (`--approve prompt`) or are pre-approved (`--approve auto`).

let usage = "mes-mock-engine [--port 17600] [--spool <dir>] [--state <dir>] [--delay-ms 0] [--steps 4] [--ttl 3600] [--paired [--host 0.0.0.0] [--approve prompt|auto]] [--no-advertise]"
var port = 17600
var host: String?
var spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-mock-engine-spool")
var state: URL?
var delayMs = 0
var steps = 4
var ttl = 3600
var paired = false
var approve = "prompt"
var advertise = true
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--port": port = Int(args.next() ?? "") ?? port
    case "--host": host = args.next()
    case "--spool": spool = URL(fileURLWithPath: args.next() ?? spool.path)
    case "--state": state = args.next().map { URL(fileURLWithPath: $0) }
    case "--delay-ms": delayMs = Int(args.next() ?? "") ?? 0
    case "--steps": steps = Int(args.next() ?? "") ?? 4
    case "--ttl": ttl = Int(args.next() ?? "") ?? ttl
    case "--paired": paired = true
    case "--approve": approve = args.next() ?? approve
    case "--no-advertise": advertise = false
    case "-h", "--help": print(usage); exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(arg)\n\(usage)\n".utf8))
        exit(2)
    }
}

var config = EngineConfiguration(id: "eng_mock", name: "MES Mock Image Engine", implementationName: "mes-mock-engine",
                                 implementationVersion: "0.1.0", spoolDirectory: spool)
config.port = port
config.outputsTTLSeconds = ttl
config.advertise = advertise
if let state { config.stateDirectory = state }
if paired {
    config.mode = .paired
    config.host = host ?? "0.0.0.0"
    if approve == "auto" {
        config.pairingApproval = EngineConfiguration.approveAll
    } else {
        config.pairingApproval = { @Sendable (prompt: PairingPrompt) async -> Bool in
            print("Pairing request from “\(prompt.clientName)” (\(prompt.clientID)). Its screen should show \(prompt.code). Approve? [y/N] ")
            let answer: String? = await Task.detached { readLine() }.value
            return answer?.lowercased().hasPrefix("y") == true
        }
    }
} else if let host {
    config.host = host
}
let basePath = config.basePath
let server = MESEngineServer(engine: MockImageEngine(stepDelay: .milliseconds(delayMs), steps: steps), configuration: config)
let scheme = paired ? "https" : "http"
let modeNote = paired ? "paired mode, approve: \(approve)" : "open mode, loopback only"
let bindHost = config.host
try await server.run { port in
    print("mes-mock-engine listening on \(scheme)://\(bindHost):\(port)\(basePath) (\(modeNote))")
}
