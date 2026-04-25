// swift-tools-version: 6.1

import PackageDescription
import CompilerPluginSupport

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
        .library(name: "BaseChatTools", targets: ["BaseChatTools"]),
        .executable(name: "bck-tools", targets: ["bck-tools"]),
    ],
    traits: [
        .default(enabledTraits: ["MLX", "Llama", "Ollama"]),
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
        .trait(name: "Llama", description: "Enable the llama.cpp (GGUF) inference backend"),
        .trait(name: "Ollama", description: "Self-hosted / private-datacenter HTTP inference. Moves out of defaults in next major."),
        .trait(name: "CloudSaaS", description: "Third-party SaaS providers (Claude, OpenAI). Off by default."),
        // Fuzz is intentionally NOT a default trait. Enabling it adds BaseChatBackends
        // (and transitively LlamaSwift) to fuzz-chat, which conflicts with the MLX
        // integration test targets in the auto-generated Xcode scheme. Run the fuzzer via
        // scripts/fuzz.sh, which passes --traits Fuzz,MLX,Llama explicitly.
        .trait(name: "Fuzz", description: "Enable real inference backends in fuzz-chat (Ollama, Llama, Foundation). Required by scripts/fuzz.sh; not needed for swift test or xcodebuild test."),
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
        // swift-syntax for the @ToolSchema macro plugin. Pinned to 600.0.x to
        // match the version mlx-swift-lm pulls in transitively — a wider range
        // would produce a duplicate-dependency resolution conflict. 600.x ships
        // ABI-compatible macro APIs for Swift 5.10 / 6.0 and builds fine on
        // Swift 6.1+. Do not bump beyond what the installed toolchain supports.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"601.0.0"),
    ],
    targets: [
        // Macro compiler plugin: implements @ToolSchema. Runs at build time in
        // the compiler's plugin host, not in app binaries. Only target that
        // pulls swift-syntax into the graph.
        .macro(
            name: "BaseChatMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            path: "Sources/BaseChatMacrosPlugin"
        ),
        // Inference: models, protocols, services — no SwiftData, no heavy ML deps.
        // Hosts the @ToolSchema attribute declaration so callers get the macro
        // for free wherever JSONSchemaValue is in scope.
        .target(
            name: "BaseChatInference",
            dependencies: [
                "BaseChatMacrosPlugin",
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/BaseChatInference",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
        ),
        // UI: SwiftUI views and view models — needs both inference and persistence
        .target(
            name: "BaseChatUI",
            dependencies: ["BaseChatCore", "BaseChatInference"],
            path: "Sources/BaseChatUI",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
        ),
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: ["BaseChatCore", "BaseChatInference", "BaseChatTestSupport"]
        ),
        // Tests for the shared test-helper module itself (e.g. `withTimeout`).
        // Kept as a dedicated target so hang-sabotage helpers don't accrete
        // inside product-suite test targets and so they can be exercised
        // with `swift test --filter BaseChatTestSupportTests`.
        .testTarget(
            name: "BaseChatTestSupportTests",
            dependencies: ["BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatInferenceTests",
            dependencies: [
                "BaseChatInference",
                "BaseChatTestSupport",
                "BaseChatMacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        // Swift Testing suites split from BaseChatInferenceTests to prevent a
        // libmalloc double-free SIGABRT that occurs when XCTest and Swift Testing
        // harnesses both initialise in the same process (~25% of CI runs).
        .testTarget(
            name: "BaseChatInferenceSwiftTestingTests",
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
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
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
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
        // BaseChatBackends is conditional on the Fuzz trait to avoid a llama.framework
        // copy conflict with BaseChatMLXIntegrationTests in the auto-generated Xcode scheme.
        // Use scripts/fuzz.sh (which passes --traits Fuzz,MLX,Llama) to run the fuzzer.
        .executableTarget(
            name: "fuzz-chat",
            dependencies: [
                "BaseChatFuzz",
                "BaseChatInference",
                "BaseChatTestSupport",
                .target(name: "BaseChatBackends", condition: .when(traits: ["Fuzz"])),
            ],
            path: "Sources/fuzz-chat",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("Fuzz", .when(traits: ["Fuzz"])),
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
        ),
        // BaseChatTools: end-to-end tool-calling validation harness.
        // Ships a fixed reference toolset (now, calc, read_file, list_dir,
        // http_get_fixture), a declarative scenario runner, and a JSONL
        // transcript logger. Library target so the test suite can exercise
        // the runner against in-process scripted backends; the CLI lives in
        // the `bck-tools` executable target below.
        .target(
            name: "BaseChatTools",
            dependencies: [
                "BaseChatInference",
            ],
            path: "Sources/BaseChatTools",
            exclude: ["Scenarios/built-in/README.md", "README.md"],
            resources: [
                .copy("Scenarios/built-in"),
            ]
        ),
        .executableTarget(
            name: "bck-tools",
            dependencies: [
                "BaseChatTools",
                "BaseChatBackends",
                "BaseChatInference",
            ],
            path: "Sources/bck-tools",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
        ),
        .testTarget(
            name: "BaseChatToolsTests",
            dependencies: [
                "BaseChatTools",
                "BaseChatInference",
                "BaseChatTestSupport",
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
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
