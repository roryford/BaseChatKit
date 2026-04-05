import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI
import BaseChatBackends

/// The simplest possible BaseChatKit app — under 40 lines.
///
/// This registers all built-in backends, creates a persistent SwiftData store,
/// and presents the standard ChatView. No model curation, no custom UI.
@main
struct MinimalExampleApp: App {
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager = SessionManagerViewModel()

    private let modelContainer: ModelContainer

    init() {
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "Minimal Chat",
            bundleIdentifier: "com.basechatkit.minimal-example"
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

        self.modelContainer = try! ModelContainerFactory.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            MinimalContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
        }
        .modelContainer(modelContainer)
    }
}
