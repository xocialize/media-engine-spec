// swift-tools-version: 6.2
import PackageDescription

// MESKit — the Swift SDKs for the Media Engine Specification (docs/BUILD-PLAN.md).
//
//   MESCore        wire types for every schema, the JSON value type, a JSON Schema (subset) validator, the
//                  Image profile's operations table, the pairing code. Foundation (+ CryptoKit) only.
//   MESEngineKit   the engine side of Base 0.1 on Hummingbird 2: routes, jobs, uploads, grants, SSE, retention,
//                  the origin guard. Engine authors implement `MediaEngine` (descriptors + run).
//   MockEngineCore the 13 Image-profile operations with synthetic, rule-abiding results (CoreGraphics).
//   MockEngine     `mes-mock-engine`, the executable.
let package = Package(
    name: "MESKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MESCore", targets: ["MESCore"]),
        .library(name: "MESEngineKit", targets: ["MESEngineKit"]),
        .library(name: "MockEngineCore", targets: ["MockEngineCore"]),
        .executable(name: "mes-mock-engine", targets: ["MockEngine"]),
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
    ],
    targets: [
        .target(
            name: "MESCore",
            resources: [.copy("Resources/image-operations.json"), .copy("Resources/image-vocabulary.json")]
        ),
        .target(
            name: "MESEngineKit",
            dependencies: [
                "MESCore",
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
        .target(name: "MockEngineCore", dependencies: ["MESEngineKit"]),
        .executableTarget(name: "MockEngine", dependencies: ["MockEngineCore"]),
        .testTarget(name: "MESCoreTests", dependencies: ["MESCore"]),
        .testTarget(
            name: "MESEngineKitTests",
            dependencies: ["MESEngineKit", "MockEngineCore", .product(name: "HummingbirdTesting", package: "hummingbird"),
                           .product(name: "Crypto", package: "swift-crypto"),
                           .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
