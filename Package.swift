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
//                  WebSocket events, a grant server. Foundation, CryptoKit and Network only.
//   MESInProcess   an engine in the client's process behind the same `EngineConnection` (Desktop's ForgeCore).
//   MESFormsUI     SwiftUI forms rendered from descriptors: parameters by UI hint, model offers with licences,
//                  extensions (DesignScaffold tokens). `mes-forms-gallery` previews every mock descriptor.
//   MockEngineCore the 13 Image-profile operations with synthetic, rule-abiding results (CoreGraphics).
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
        .library(name: "MockEngineCore", targets: ["MockEngineCore"]),
        .executable(name: "mes-mock-engine", targets: ["MockEngine"]),
        .executable(name: "mes", targets: ["MESCLI"]),
        .executable(name: "mes-forms-gallery", targets: ["MESFormsGallery"]),
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
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .target(name: "MESClientKit", dependencies: ["MESCore"]),
        .target(name: "MESInProcess", dependencies: ["MESClientKit", "MESEngineCore"]),
        .target(
            name: "MESFormsUI",
            dependencies: ["MESCore", .product(name: "DesignScaffold", package: "DesignScaffold"),
                           .product(name: "DesignScaffoldControls", package: "DesignScaffold")]
        ),
        .target(name: "MockEngineCore", dependencies: ["MESEngineCore"]),
        .executableTarget(name: "MockEngine", dependencies: ["MockEngineCore", "MESEngineKit"]),
        .executableTarget(
            name: "MESCLI",
            dependencies: ["MESClientKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "MESFormsGallery", dependencies: ["MESFormsUI", "MockEngineCore"]),
        .testTarget(name: "MESCoreTests", dependencies: ["MESCore"]),
        .testTarget(
            name: "MESEngineKitTests",
            dependencies: ["MESEngineKit", "MESEngineCore", "MockEngineCore", .product(name: "HummingbirdTesting", package: "hummingbird"),
                           .product(name: "Crypto", package: "swift-crypto"),
                           .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(
            name: "MESClientKitTests",
            dependencies: ["MESClientKit", "MESInProcess", "MESEngineKit", "MockEngineCore"]
        ),
        .testTarget(
            name: "MESFormsUITests",
            dependencies: ["MESFormsUI", "MESInProcess", "MESEngineCore", "MockEngineCore"]
        ),
    ]
)
