// swift-tools-version: 6.2
import PackageDescription

// MESKit — the Swift SDKs for the Media Engine Specification (docs/BUILD-PLAN.md).
//
//   MESCore        wire types for every schema, the JSON value type, a JSON Schema (subset) validator, the
//                  Image profile's operations table, the pairing code. Foundation (+ CryptoKit) only.
//   MESEngineCore  the engine core with no networking stack: `MediaEngine` (what engine authors implement), the job
//                  registry, spool and retention, grant fetching, configuration.
//   MESEngineKit   the engine side of Base 0.1 on Hummingbird 2: routes, uploads, SSE, WebSocket, MCP, TLS and
//                  pairing, DNS-SD, the origin guard. Re-exports MESEngineCore.
//   MESClientKit   the client side: discovery, pairing with a pinned certificate, jobs, uploads, downloads, SSE and
//                  WebSocket events, a grant server, and an engine picker for apps that know several servers.
//                  Foundation, CryptoKit and Network only.
//   MESInProcess   an engine in the client's process behind the same `EngineConnection` (Desktop's ForgeCore).
//   MESFormsUI     SwiftUI forms rendered from descriptors: parameters by UI hint, model offers with licences,
//                  extensions (DesignScaffold tokens). `mes-forms-gallery` previews every mock descriptor.
//   MESEngineUI    an engine app's own console (Engines-PRD ENG-9): the queue, the enabled set of models with a card
//                  per model, a System monitor and the menu-bar item. Every Pixel Agency engine shares it. The
//                  `SystemSensors` trait (default on) adds temperatures, fans and power, read through private
//                  interfaces; an App Store build turns it off. A Plugins page for engines whose models come as plugins,
//                  and engine memory summed over a host and its worker processes (Gaea). `mes-console-gallery` previews
//                  it over the mock engine.
//   MESConformance the conformance suite (BASE-nnn, IMAGE-nnn) and `mes-conformance`, its CLI.
//   MockEngineCore the 15 Image-profile operations with synthetic, rule-abiding results (CoreGraphics).
//   MockEngine     `mes-mock-engine`, the executable.
//   MESCLI         `mes`, the command-line client on MESClientKit.
let package = Package(
    name: "MESKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MESCore", targets: ["MESCore"]),
        .library(name: "MESEngineCore", targets: ["MESEngineCore"]),
        .library(name: "MESEngineKit", targets: ["MESEngineKit"]),
        .library(name: "MESClientKit", targets: ["MESClientKit"]),
        .library(name: "MESInProcess", targets: ["MESInProcess"]),
        .library(name: "MESFormsUI", targets: ["MESFormsUI"]),
        .library(name: "MESEngineUI", targets: ["MESEngineUI"]),
        .library(name: "MESConformance", targets: ["MESConformance"]),
        .library(name: "MockEngineCore", targets: ["MockEngineCore"]),
        .executable(name: "mes-mock-engine", targets: ["MockEngine"]),
        .executable(name: "mes", targets: ["MESCLI"]),
        .executable(name: "mes-forms-gallery", targets: ["MESFormsGallery"]),
        .executable(name: "mes-console-gallery", targets: ["MESConsoleGallery"]),
        .executable(name: "mes-conformance", targets: ["MESConformanceCLI"]),
    ],
    traits: [
        .trait(name: "SystemSensors",
               description: "Temperatures, fans and power on MESEngineUI's System page, read through private interfaces "
                   + "(IOHIDEventSystem, IOReport, AppleSMC). Leave it off for an App Store build."),
        .default(enabledTraits: ["SystemSensors"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/xocialize/DesignScaffold.git", from: "0.25.0"),
    ],
    targets: [
        .target(
            name: "MESCore",
            resources: [.copy("Resources/image-operations.json"), .copy("Resources/image-vocabulary.json")]
        ),
        .target(name: "MESEngineCore", dependencies: ["MESCore"]),
        .target(
            name: "MESEngineKit",
            dependencies: [
                "MESCore",
                "MESEngineCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            ]
        ),
        .target(name: "MESClientKit", dependencies: ["MESCore"]),
        .target(name: "MESInProcess", dependencies: ["MESClientKit", "MESEngineCore"]),
        .target(
            name: "MESFormsUI",
            dependencies: ["MESCore", .product(name: "DesignScaffold", package: "DesignScaffold"),
                           .product(name: "DesignScaffoldControls", package: "DesignScaffold")]
        ),
        .target(
            name: "MESEngineUI",
            dependencies: ["MESCore", "MESEngineCore", .product(name: "DesignScaffold", package: "DesignScaffold"),
                           .product(name: "DesignScaffoldStatus", package: "DesignScaffold")],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "MockEngineCore", dependencies: ["MESEngineCore"]),
        .executableTarget(name: "MockEngine", dependencies: ["MockEngineCore", "MESEngineKit"]),
        .executableTarget(
            name: "MESCLI",
            dependencies: ["MESClientKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "MESFormsGallery", dependencies: ["MESFormsUI", "MockEngineCore"]),
        .executableTarget(name: "MESConsoleGallery", dependencies: ["MESEngineUI", "MESEngineKit", "MockEngineCore"]),
        .target(
            name: "MESConformance",
            dependencies: ["MESCore", "MESClientKit", "MESEngineKit", "MockEngineCore"],
            resources: [.copy("Resources/schemas")]
        ),
        .executableTarget(
            name: "MESConformanceCLI",
            dependencies: ["MESConformance", "MESClientKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "MESCoreTests", dependencies: ["MESCore"]),
        .testTarget(
            name: "MESEngineKitTests",
            dependencies: ["MESEngineKit", "MESEngineCore", "MockEngineCore", .product(name: "HummingbirdTesting", package: "hummingbird"),
                           .product(name: "Crypto", package: "swift-crypto"),
                           .product(name: "MCP", package: "swift-sdk"),
                           .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                           .product(name: "UnixSignals", package: "swift-service-lifecycle")]
        ),
        .testTarget(
            name: "MESClientKitTests",
            dependencies: ["MESClientKit", "MESInProcess", "MESEngineKit", "MockEngineCore"]
        ),
        .testTarget(
            name: "MESFormsUITests",
            dependencies: ["MESFormsUI", "MESInProcess", "MESEngineCore", "MockEngineCore"]
        ),
        .testTarget(name: "MESEngineUITests", dependencies: ["MESEngineUI", "MESEngineCore", "MESCore"]),
        .testTarget(
            name: "MESConformanceTests",
            dependencies: ["MESConformance", "MESEngineKit", "MESEngineCore", "MockEngineCore"]
        ),
    ]
)
