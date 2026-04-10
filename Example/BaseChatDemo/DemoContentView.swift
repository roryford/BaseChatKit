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

    let inferenceService: InferenceService

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
            let persistence = SwiftDataPersistenceProvider(modelContext: modelContext)
            viewModel.configure(persistence: persistence)
            sessionManager.configure(persistence: persistence)
            viewModel.setAvailableEndpoints(cloudEndpoints)

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
                do {
                    try sessionManager.createSession()
                } catch {
                    viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
                }
            }

            // Wire AI auto-rename: fires after the first user message in a session.
            // We defer the rename call until generation finishes so the rename
            // inference request does not compete with the active streaming reply.
            viewModel.onFirstMessage = { [inferenceService] session, text in
                Task { @MainActor in
                    while viewModel.isGenerating {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    await sessionManager.autoRenameSession(
                        session,
                        firstMessage: text,
                        inferenceService: inferenceService
                    )
                }
            }
        }
        .onChange(of: viewModel.selectedModel) {
            viewModel.dispatchSelectedLoad()
        }
        .onChange(of: viewModel.selectedEndpoint) {
            viewModel.dispatchSelectedLoad()
        }
        .onChange(of: cloudEndpoints) {
            viewModel.setAvailableEndpoints(cloudEndpoints)
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
                } else if viewModel.isLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.activeError != nil {
                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    do {
                        try sessionManager.createSession()
                    } catch {
                        viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
                    }
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
            }
        }
    }
}
