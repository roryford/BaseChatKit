import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI
import BaseChatBackends

/// Demonstrates BaseChatKit's text-to-speech narration feature.
///
/// Configures only the narration feature flag and provides an
/// `AVSpeechNarrationProvider` for on-device speech synthesis.
/// All other features are disabled to keep the example focused.
@main
struct NarrationExampleApp: App {
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager = SessionManagerViewModel()
    @State private var narrationViewModel: NarrationViewModel

    private let modelContainer: ModelContainer

    init() {
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "Narration Example",
            bundleIdentifier: "com.basechatkit.narration-example",
            features: .init(
                showModelDownload: false,
                showStorageTab: false,
                showAdvancedSettings: false,
                showNarration: true,
                showUpgradeHint: false
            )
        )

        let service = InferenceService()
        DefaultBackends.register(with: service)

        let vm = ChatViewModel(inferenceService: service)
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        _chatViewModel = State(initialValue: vm)

        let narration = NarrationViewModel()
        narration.configure(provider: AVSpeechNarrationProvider())
        _narrationViewModel = State(initialValue: narration)

        let schema = Schema(BaseChatSchema.allModelTypes)
        self.modelContainer = try! ModelContainer(for: schema)
    }

    var body: some Scene {
        WindowGroup {
            NarrationContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
                .environment(narrationViewModel)
        }
        .modelContainer(modelContainer)
    }
}
