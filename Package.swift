// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BaseChatKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BaseChatInference", targets: ["BaseChatInference"]),
        .library(name: "BaseChatCore", targets: ["BaseChatCore"]),
        .library(name: "BaseChatBackends", targets: ["BaseChatBackends"]),
        .library(name: "BaseChatUI", targets: ["BaseChatUI"]),
        .library(name: "BaseChatFuzz", targets: ["BaseChatFuzz"]),
        .executable(name: "fuzz-chat", targets: ["fuzz-chat"]),
    ],
    traits: [
        .default(enabledTraits: ["MLX", "Llama"]),
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
        .trait(name: "Llama", description: "Enable the llama.cpp (GGUF) inference backend"),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        // Pinned to main-branch commit — mlx-swift-lm 2.31.3 uses HuggingFace.HubCache in
        // MLXLMCommon without declaring swift-huggingface as an explicit SPM dependency.
        // Swift 6.3 / Xcode 26 enforces this strictly. The fix (decoupled MLXHuggingFace
        // target) landed in main but has no tag yet. Revisit when ≥2.32.0 is tagged.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "d1b14783c93902b74c1211f480ece8f776f4c29c"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        // Explicit dep required: mlx-swift-lm no longer pulls swift-transformers transitively.
        // The MLXHuggingFace macro generates `AutoTokenizer.from(modelFolder:)` which lives here.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
        // Pinned version: 2.8772.0 (Package.resolved rev 3fec82010cfbe56aa78bb4177c8f4f33dace8779).
        // Wraps llama.cpp build b8772 as a pre-built xcframework binary.
        // See docs/LLAMA_CONTRACT.md for the full C API contract, threading rules, and upgrade procedure.
        .package(url: "https://github.com/mattt/llama.swift", from: "2.8772.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        // Test-only: SwiftUI view-tree inspection for accessibility contract tests.
        // Must never appear in any production target.
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3"),
    ],
    targets: [
        // Inference: models, protocols, services — no SwiftData, no heavy ML deps
        .target(
            name: "BaseChatInference",
            dependencies: [
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/BaseChatInference"
        ),
        // Core: SwiftData persistence (schema, @Model types, container, provider)
        // plus chat export. Re-exports BaseChatInference for source compatibility.
        .target(
            name: "BaseChatCore",
            dependencies: ["BaseChatInference"],
            path: "Sources/BaseChatCore"
        ),
        // Backends: MLX, llama.cpp, Foundation, cloud
        .target(
            name: "BaseChatBackends",
            dependencies: [
                "BaseChatInference",
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
                .product(name: "LlamaSwift", package: "llama.swift", condition: .when(traits: ["Llama"])),
            ],
            path: "Sources/BaseChatBackends",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        // UI: SwiftUI views and view models — needs both inference and persistence
        .target(
            name: "BaseChatUI",
            dependencies: ["BaseChatCore", "BaseChatInference"],
            path: "Sources/BaseChatUI"
        ),
        // Shared test mocks and utilities
        .target(
            name: "BaseChatTestSupport",
            dependencies: [
                "BaseChatCore",
                "BaseChatInference",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/BaseChatTestSupport",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: ["BaseChatCore", "BaseChatInference", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatInferenceTests",
            dependencies: ["BaseChatInference", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatBackendsTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatUI",
                "BaseChatCore",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: [
                "BaseChatUI",
                "BaseChatCore",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "BaseChatE2ETests",
            dependencies: ["BaseChatBackends", "BaseChatUI", "BaseChatCore", "BaseChatInference", "BaseChatTestSupport"],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        .testTarget(
            name: "BaseChatSnapshotTests",
            dependencies: [
                "BaseChatUI",
                "BaseChatCore",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic.
        // Trait-free so it never pulls MLX/Llama transitively — backend selection
        // happens in `fuzz-chat` (executable) and `BaseChatFuzzTests` (XCTest harness).
        .target(
            name: "BaseChatFuzz",
            dependencies: ["BaseChatInference"],
            path: "Sources/BaseChatFuzz",
            resources: [.process("Resources")]
        ),
        // CLI driver. Wires Ollama, Llama, Foundation; MLX runs via xcodebuild fuzz path.
        .executableTarget(
            name: "fuzz-chat",
            dependencies: ["BaseChatFuzz", "BaseChatBackends", "BaseChatInference", "BaseChatTestSupport"],
            path: "Sources/fuzz-chat",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        .testTarget(
            name: "BaseChatFuzzTests",
            dependencies: [
                "BaseChatFuzz",
                "BaseChatBackends",
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
        // Xcode-only: real MLX model inference requiring Metal shader library.
        // Cannot run via `swift test` — MLX's metallib is only compiled by Xcode.
        // Run with: xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests
        .testTarget(
            name: "BaseChatMLXIntegrationTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatCore",
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
