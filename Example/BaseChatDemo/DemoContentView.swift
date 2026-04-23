import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatUI

struct DemoContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query(filter: #Predicate<APIEndpoint> { $0.isEnabled }, sort: \APIEndpoint.createdAt)
    private var cloudEndpoints: [APIEndpoint]

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var isModelManagementPresented = false
    @State private var isToolPolicyPresented = false

    let inferenceService: InferenceService

    /// When `true`, the auto-model-load and related onAppear work is skipped
    /// so that UI tests start from a deterministic empty state.
    var skipAutoModelLoad: Bool = false

    var body: some View {
        // Read the gate's pending queue so SwiftUI observes changes and the
        // `.sheet(item:)` binding below re-evaluates when a new approval
        // is enqueued. Without this the binding's `get` closure is stale.
        let _ = viewModel.toolApprovalGate?.pending.count

        return NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebar
        } detail: {
            ChatView(showModelManagement: $isModelManagementPresented) {
                ChatEmptyStateView()
            }
                .toolbar {
                    // .topBarLeading is iOS-only; macOS NavigationSplitView manages
                    // sidebar visibility via its own controls so this button is not
                    // needed on macOS. (#375)
                    #if os(iOS)
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                preferredCompactColumn = .sidebar
                            } label: {
                                Label("Show Sidebar", systemImage: "sidebar.leading")
                            }
                            .accessibilityLabel("Show Sidebar")
                            .accessibilityIdentifier("show-sidebar-button")
                        }
                    }
                    #endif
                }
        }
        .sheet(isPresented: $isModelManagementPresented) {
            ModelManagementSheet()
                .environment(viewModel)
                .environment(managementViewModel)
        }
        .sheet(isPresented: $isToolPolicyPresented) {
            ToolPolicyView()
                .environment(viewModel)
        }
        .sheet(isPresented: approvalSheetIsPresented) {
            if let call = viewModel.toolApprovalGate?.pending.first {
                ToolApprovalSheet(call: call)
                    .environment(viewModel)
            } else {
                // Belt-and-braces: the binding only flips to `true` when
                // ``pending.first`` exists, but a race during dismiss can
                // leave the queue empty while the sheet closes. Emit a
                // drop-down so we don't present an empty sheet shell.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onAppear {
            if horizontalSizeClass == .compact {
                columnVisibility = .detailOnly
                preferredCompactColumn = .detail
            }

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

            // On first launch, createSession() above activates the new session.
            // On subsequent launches, sessions already exist but none is active yet —
            // restore the most recent one so the chat detail is ready immediately
            // without waiting for the user to tap a row in the sidebar.
            if sessionManager.activeSession == nil, let first = sessionManager.sessions.first {
                sessionManager.activeSession = first
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
                if horizontalSizeClass == .compact {
                    columnVisibility = .detailOnly
                    preferredCompactColumn = .detail
                }
                viewModel.switchToSession(session)
            }
        }
        .onChange(of: managementViewModel.completedDownloadCount) { _, _ in
            viewModel.refreshModels()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact {
                Button(action: createSession) {
                    Label("New Chat", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("new-chat-button")
            }

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
                .accessibilityIdentifier("sidebar-model-management-button")

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

                Button {
                    isToolPolicyPresented = true
                } label: {
                    HStack {
                        Label("Tool approval", systemImage: "checkmark.shield")
                            .font(.caption)
                        Spacer()
                        Text(policyLabel(viewModel.toolApprovalPolicy))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar-tool-policy-button")
            }
            .padding()
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                Button(action: createSession) {
                    Label("New Chat", systemImage: "plus")
                }
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("new-chat-button")
                // Cmd+N is the system convention for "new document/item" on both
                // macOS and iPadOS with a hardware keyboard.
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private func createSession() {
        do {
            try sessionManager.createSession()
        } catch {
            viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    /// Drives the presentation of the approval sheet off the gate's pending
    /// queue. Kept as a computed `Binding<Bool>` so `@Observable` tracking on
    /// the gate re-evaluates the binding whenever the queue mutates — a
    /// `.sheet(item:)` binding with `Binding(get:set:)` would not re-read
    /// without another observed property driving the re-render.
    private var approvalSheetIsPresented: Binding<Bool> {
        Binding(
            get: { (viewModel.toolApprovalGate?.pending.first) != nil },
            set: { newValue in
                guard !newValue else { return }
                // Drag-dismiss (iOS) is a dismiss without an explicit
                // decision; treat it as a denial so the pending queue
                // drains and the model recovers with a structured error.
                if let first = viewModel.toolApprovalGate?.pending.first {
                    viewModel.toolApprovalGate?.resolve(
                        callId: first.id,
                        with: .denied(reason: "dismissed")
                    )
                }
            }
        )
    }

    private func policyLabel(_ policy: UIToolApprovalGate.Policy) -> String {
        switch policy {
        case .alwaysAsk: return "Always ask"
        case .askOncePerSession: return "Once / session"
        case .autoApprove: return "Auto"
        }
    }
}

