import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI

struct MinimalContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    @State private var isModelManagementPresented = false

    var body: some View {
        NavigationStack {
            ChatView(
                showModelManagement: $isModelManagementPresented,
                apiConfiguration: { APIConfigurationView() }
            )
                .sheet(isPresented: $isModelManagementPresented) {
                    ModelManagementSheet()
                        .environment(viewModel)
                }
        }
        .onAppear {
            let persistence = SwiftDataPersistenceProvider(modelContext: modelContext)
            viewModel.configure(persistence: persistence)
            sessionManager.configure(persistence: persistence)

            viewModel.refreshModels()

            if sessionManager.sessions.isEmpty {
                _ = try? sessionManager.createSession()
            }

            sessionManager.loadSessions()
        }
    }
}
