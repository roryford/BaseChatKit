// swift-tools-version: 5.9

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
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.30.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "2a296f145c3129fea4290bb6e4a0a5fb458efa06"),
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
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
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
            dependencies: ["BaseChatBackends", "BaseChatCore", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: ["BaseChatUI", "BaseChatCore", "BaseChatTestSupport"]
        ),
    ]
)
