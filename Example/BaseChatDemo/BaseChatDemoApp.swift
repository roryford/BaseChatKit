import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI
import BaseChatBackends

@main
struct BaseChatDemoApp: App {
    @State private var chatViewModel: ChatViewModel
    @State private var modelManagementViewModel: ModelManagementViewModel
    @State private var sessionManager = SessionManagerViewModel()

    init() {
        // Configure BaseChatKit for this app
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "BaseChat Demo",
            bundleIdentifier: "com.basechatkit.demo"
        )

        let inferenceService = InferenceService()
        DefaultBackends.register(with: inferenceService)

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

    var body: some Scene {
        WindowGroup {
            DemoContentView()
                .environment(chatViewModel)
                .environment(modelManagementViewModel)
                .environment(sessionManager)
        }
        .modelContainer(for: BaseChatSchema.allModelTypes)
    }
}
