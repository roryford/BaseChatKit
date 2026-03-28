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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
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
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: ["BaseChatCore"]
        ),
        .testTarget(
            name: "BaseChatBackendsTests",
            dependencies: ["BaseChatBackends", "BaseChatCore"]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: ["BaseChatUI", "BaseChatCore"]
        ),
    ]
)
