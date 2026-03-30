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
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.30.6"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/mattt/llama.swift", from: "2.8563.0"),
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
                .product(name: "LlamaSwift", package: "llama.swift"),
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
            dependencies: ["BaseChatCore"],
            path: "Sources/BaseChatTestSupport"
        ),
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: ["BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatBackendsTests",
            dependencies: ["BaseChatBackends", "BaseChatUI", "BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: ["BaseChatUI", "BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatE2ETests",
            dependencies: ["BaseChatBackends", "BaseChatCore", "BaseChatTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
