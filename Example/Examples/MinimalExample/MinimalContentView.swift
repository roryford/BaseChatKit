import SwiftUI
import BaseChatCore
import BaseChatUI

struct MinimalContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    @State private var isModelManagementPresented = false

    var body: some View {
        NavigationStack {
            ChatView(showModelManagement: $isModelManagementPresented)
                .sheet(isPresented: $isModelManagementPresented) {
                    ModelManagementSheet()
                        .environment(viewModel)
                }
        }
        .onAppear {
            viewModel.configure(modelContext: modelContext)
            sessionManager.configure(modelContext: modelContext)

            viewModel.refreshModels()

            if sessionManager.sessions.isEmpty {
                _ = try? sessionManager.createSession()
            }

            sessionManager.loadSessions()
        }
    }
}
