import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatUI
import BaseChatBackends

@main
struct BaseChatDemoApp: App {
    @State private var chatViewModel: ChatViewModel
    @State private var modelManagementViewModel: ModelManagementViewModel
    @State private var sessionManager = SessionManagerViewModel()
    private let inferenceService: InferenceService

    /// When `true`, the app was launched with `--uitesting` and should use
    /// an in-memory store, skip auto-model-load, and disable animations.
    private let isUITesting: Bool

    // Created asynchronously in .task to avoid blocking App.init() — SwiftData
    // container setup (schema compilation + SQLite open) can stall the first
    // frame for several seconds when done on the main thread.
    @State private var modelContainer: ModelContainer?

    init() {
        let testing = CommandLine.arguments.contains("--uitesting")
        self.isUITesting = testing

        if testing {
            #if canImport(UIKit)
            UIView.setAnimationsEnabled(false)
            #endif
            UserDefaults.standard.removeObject(forKey: "showAdvancedSettings")
        }
        // Configure BaseChatKit for this app
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "BaseChat Demo",
            bundleIdentifier: "com.basechatkit.demo"
        )

        // Populate curated model recommendations
        CuratedModel.all = Self.curatedModels

        let toolRegistry = ToolRegistry()
        DemoTools.register(on: toolRegistry)

        let inferenceService = InferenceService(toolRegistry: toolRegistry)
        DefaultBackends.register(with: inferenceService)
        self.inferenceService = inferenceService

        let vm = ChatViewModel(inferenceService: inferenceService)
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        _chatViewModel = State(initialValue: vm)

        let downloadManager = BackgroundDownloadManager()
        let hfService = HuggingFaceService()
        _modelManagementViewModel = State(initialValue: ModelManagementViewModel(
            huggingFaceService: hfService,
            downloadManager: downloadManager
        ))
    }

    // MARK: - Curated Models

    private static let curatedModels: [CuratedModel] = [
        // Small — runs on any Apple Silicon device (≤ 2.5 GB)
        CuratedModel(
            id: "smollm2-360m",
            displayName: "SmolLM2 360M (Q8)",
            fileName: "smollm2-360m-instruct-q8_0.gguf",
            repoID: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 386_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 2048,
            promptTemplate: .chatML,
            description: "Tiny but capable chat model, great for testing"
        ),
        CuratedModel(
            id: "phi-4-mini-mlx",
            displayName: "Phi-4 Mini (MLX, 4-bit)",
            fileName: "Phi-4-mini-instruct-4bit",
            repoID: "mlx-community/Phi-4-mini-instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 2_400_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 4096,
            promptTemplate: .phi,
            description: "Microsoft's compact reasoning model, optimized for Apple Silicon"
        ),
        // Medium — 8 GB+ RAM devices (≤ 4.5 GB)
        CuratedModel(
            id: "mistral-7b-gguf",
            displayName: "Mistral 7B Instruct v0.3 (Q4_K_M)",
            fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
            repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 4_370_000_000,
            recommendedFor: [.medium, .large, .xlarge],
            contextSize: 4096,
            promptTemplate: .mistral,
            description: "Excellent general-purpose chat model"
        ),
        CuratedModel(
            id: "llama-3.2-3b-mlx",
            displayName: "Llama 3.2 3B Instruct (MLX, 4-bit)",
            fileName: "Llama-3.2-3B-Instruct-4bit",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 1_800_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 8192,
            promptTemplate: .llama3,
            description: "Meta's efficient 3B model with 8K context"
        ),
        // Large — 16 GB+ RAM devices (≤ 6 GB)
        CuratedModel(
            id: "qwen-2.5-7b-mlx",
            displayName: "Qwen 2.5 7B Instruct (MLX, 4-bit)",
            fileName: "Qwen2.5-7B-Instruct-4bit",
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 4_500_000_000,
            recommendedFor: [.large, .xlarge],
            contextSize: 8192,
            promptTemplate: .chatML,
            description: "Strong multilingual model from Alibaba"
        ),
    ]

    var body: some Scene {
        WindowGroup {
            if let container = modelContainer {
                DemoContentView(inferenceService: inferenceService, skipAutoModelLoad: isUITesting)
                    .environment(chatViewModel)
                    .environment(modelManagementViewModel)
                    .environment(sessionManager)
                    #if os(macOS)
                    .frame(minWidth: 600, minHeight: 400)
                    #endif
                    .modelContainer(container)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        let testing = isUITesting
                        modelContainer = await Task.detached(priority: .userInitiated) {
                            let config = ModelConfiguration("BaseChatDemo", isStoredInMemoryOnly: testing)
                            return try! ModelContainerFactory.makeContainer(configurations: [config])
                        }.value
                    }
            }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 700)
        #endif
    }
}
