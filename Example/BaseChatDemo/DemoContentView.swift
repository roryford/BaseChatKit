import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatUI

struct DemoContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    @Query(filter: #Predicate<APIEndpoint> { $0.isEnabled }, sort: \APIEndpoint.createdAt)
    private var cloudEndpoints: [APIEndpoint]

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isModelManagementPresented = false

    /// When `true`, the auto-model-load and related onAppear work is skipped
    /// so that UI tests start from a deterministic empty state.
    var skipAutoModelLoad: Bool = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            ChatView(showModelManagement: $isModelManagementPresented)
        }
        .sheet(isPresented: $isModelManagementPresented) {
            ModelManagementSheet()
                .environment(viewModel)
                .environment(managementViewModel)
        }
        .onAppear {
            viewModel.configure(modelContext: modelContext)
            sessionManager.configure(modelContext: modelContext)

            if !skipAutoModelLoad {
                viewModel.refreshModels()
                viewModel.autoSelectFirstRunModel()

                // If no model was selected (e.g. first-run already fired before
                // backends were configured), fall back to the Foundation model.
                if viewModel.selectedModel == nil,
                   let foundation = viewModel.availableModels.first(where: { $0.modelType == .foundation }) {
                    viewModel.selectedModel = foundation
                }

                viewModel.startMemoryMonitoring()
            }

            sessionManager.loadSessions()

            if sessionManager.sessions.isEmpty {
                sessionManager.createSession()
            }

            // Wire AI auto-rename: fires after the first user message in a session.
            viewModel.onFirstMessage = { [inferenceService = viewModel.inferenceService] session, text in
                Task {
                    await sessionManager.autoRenameSession(
                        session,
                        firstMessage: text,
                        inferenceService: inferenceService
                    )
                }
            }
        }
        .onChange(of: viewModel.selectedModel) {
            if viewModel.selectedModel != nil {
                viewModel.selectedEndpoint = nil
            }
            Task { await viewModel.loadSelectedModel() }
        }
        .onChange(of: viewModel.selectedEndpoint) {
            if viewModel.selectedEndpoint != nil {
                viewModel.selectedModel = nil
            }
            if let endpoint = viewModel.selectedEndpoint {
                Task { await viewModel.loadCloudEndpoint(endpoint) }
            }
        }
        .onChange(of: sessionManager.activeSession) { _, newSession in
            if let session = newSession {
                viewModel.switchToSession(session)
            }
        }
        .onChange(of: managementViewModel.completedDownloadCount) { _, _ in
            viewModel.refreshModels()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SessionListView()

            Divider()

            // Simple model section
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    isModelManagementPresented = true
                } label: {
                    HStack {
                        Text(viewModel.selectedModel?.name ?? "No Model Selected")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if viewModel.isModelLoaded {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding()
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    sessionManager.createSession()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
        }
    }
}
