// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift Package Manager required to build this package.

import PackageDescription

let package = Package(
    name: "swift-llama-cpp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SwiftLlama",
            targets: ["SwiftLlama"]
        )
    ],
    targets: [
        // Binary target from upstream ggml-org/llama.cpp release b9821.
        // The xcframework contains pre-built static libraries for ios-arm64 and ios-arm64-simulator.
        .binaryTarget(
            name: "llama",
            path: "llama.xcframework"
        ),
        // Swift wrapper around the llama.cpp C API.
        .target(
            name: "SwiftLlama",
            dependencies: ["llama"],
            path: "Sources/SwiftLlama"
        ),
        .testTarget(
            name: "SwiftLlamaTests",
            dependencies: ["SwiftLlama"],
            path: "Tests"
        )
    ]
)
