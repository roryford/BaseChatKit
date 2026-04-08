// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BaseChatKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BaseChatCore", targets: ["BaseChatCore"]),
        .library(name: "BaseChatBackends", targets: ["BaseChatBackends"]),
        .library(name: "BaseChatUI", targets: ["BaseChatUI"]),
    ],
    traits: [
        .default(enabledTraits: ["MLX"]),
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
        .trait(name: "Llama", description: "Enable the llama.cpp (GGUF) inference backend"),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/mattt/llama.swift", from: "2.8672.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        // Core: models, protocols, services — no heavy ML deps
        .target(
            name: "BaseChatCore",
            dependencies: [
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/BaseChatCore"
        ),
        // Backends: MLX, llama.cpp, Foundation, cloud
        .target(
            name: "BaseChatBackends",
            dependencies: [
                "BaseChatCore",
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "LlamaSwift", package: "llama.swift", condition: .when(traits: ["Llama"])),
            ],
            path: "Sources/BaseChatBackends"
        ),
        // UI: SwiftUI views and view models
        .target(
            name: "BaseChatUI",
            dependencies: ["BaseChatCore"],
            path: "Sources/BaseChatUI"
        ),
        // Shared test mocks and utilities
        .target(
            name: "BaseChatTestSupport",
            dependencies: [
                "BaseChatCore",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/BaseChatTestSupport"
        ),
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: ["BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatBackendsTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatUI",
                "BaseChatCore",
                "BaseChatTestSupport",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: ["BaseChatUI", "BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatE2ETests",
            dependencies: ["BaseChatBackends", "BaseChatUI", "BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatSnapshotTests",
            dependencies: [
                "BaseChatUI",
                "BaseChatCore",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Xcode-only: real MLX model inference requiring Metal shader library.
        // Cannot run via `swift test` — MLX's metallib is only compiled by Xcode.
        // Run with: xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests
        .testTarget(
            name: "BaseChatMLXIntegrationTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatCore",
                "BaseChatTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
