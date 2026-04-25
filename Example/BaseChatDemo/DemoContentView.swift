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

    /// Tool registry shared with `inferenceService`. Held here so the demo
    /// scenario runner can install scenario-specific variant executors.
    let toolRegistry: ToolRegistry

    /// Sandbox root the demo's filesystem tools resolve paths against. Held
    /// here (rather than re-resolved per-scenario) so `--uitesting` runs use
    /// a stable temp directory the test harness can inspect.
    let sandboxRoot: URL

    /// When `true`, the auto-model-load and related onAppear work is skipped
    /// so that UI tests start from a deterministic empty state.
    var skipAutoModelLoad: Bool = false

    /// Buffer holding any ``InboundPayload`` that arrived during the
    /// cold-launch window, before persistence was wired. Drained once
    /// the `onAppear` configuration completes.
    var pendingPayloadBuffer: PendingPayloadBuffer?

    /// Optional demo-scenario ID supplied via `--bck-demo-scenario`. Resolved
    /// to a ``DemoScenario`` and run after persistence is wired in `onAppear`.
    var pendingDemoScenarioID: String?

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
                ChatEmptyStateView(runScenario: runScenario)
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

            // Seed an empty session and/or drain any buffered payload.
            //
            // On cold-launch with a pending payload, `ingest(_:)` will create
            // its own session — seeding an empty one here would leave an orphan
            // in the sidebar (#677). We peek at the buffer before deciding
            // whether to create the placeholder session.
            Task { @MainActor in
                let hasPendingPayload = await pendingPayloadBuffer?.peek() != nil

                if !hasPendingPayload && sessionManager.sessions.isEmpty {
                    do {
                        try sessionManager.createSession()
                    } catch {
                        viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
                    }
                }

                // On first launch, createSession() above activates the new session.
                // On subsequent launches, sessions already exist but none is active
                // yet — restore the most recent one so the chat detail is ready
                // immediately without waiting for the user to tap a row in the sidebar.
                if sessionManager.activeSession == nil, let first = sessionManager.sessions.first {
                    sessionManager.activeSession = first
                }

                // Drain any payload that arrived during the cold-launch window
                // where persistence was not yet wired. Runs after the
                // `viewModel.configure(persistence:)` call above so the ingest
                // path can safely create sessions.
                if let pendingPayloadBuffer, let payload = await pendingPayloadBuffer.drain() {
                    await viewModel.ingest(payload)
                }

                // Demo-scenario cold-launch path — `--bck-demo-scenario <id>`
                // resolved to a scenario in `BaseChatDemoApp.init()` and
                // forwarded here. Runs *after* the empty initial-session
                // seeding above so the scenario's session becomes the active
                // one rather than competing with a placeholder.
                if let id = pendingDemoScenarioID, let scenario = DemoScenarios.scenario(id: id) {
                    runScenario(scenario)
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
                // Guard against the back-channel loop with `onChange(of:
                // viewModel.activeSession)` below: when `ingest(_:)` creates
                // a session and switches `viewModel` to it, the sibling
                // handler mirrors the change into `sessionManager`, which
                // would re-enter `switchToSession` here and (because
                // `isGenerating` is already `true`) call `stopGeneration()`
                // mid-stream, wiping the ingested reply. Only re-activate
                // if the view model is currently on a different session.
                if viewModel.activeSession?.id != session.id {
                    viewModel.switchToSession(session)
                }
            }
        }
        .onChange(of: viewModel.activeSession) { _, newSession in
            // Keep `SessionManagerViewModel.activeSession` in sync when
            // `ChatViewModel.ingest(_:)` creates + switches to a new
            // session of its own. Without this, the sidebar binding
            // stays on whatever session was previously active and the
            // user sees the wrong detail pane.
            guard let newSession else { return }
            if sessionManager.activeSession?.id != newSession.id {
                sessionManager.loadSessions()
                sessionManager.activeSession = newSession
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
            ToolbarItem(placement: toolbarPlacement) {
                Menu {
                    ForEach(DemoScenarios.all) { scenario in
                        Button {
                            runScenario(scenario)
                        } label: {
                            Label(scenario.title, systemImage: scenario.systemImage)
                        }
                        .accessibilityIdentifier("demo-menu-\(scenario.id)")
                    }
                } label: {
                    Label("Demos", systemImage: "sparkles")
                }
                .accessibilityLabel("Demo scenarios")
                .accessibilityIdentifier("demos-menu-button")
                .disabled(viewModel.isGenerating)
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

    /// Closure passed down to `ChatEmptyStateView` and the `Demos` toolbar
    /// menu so both surfaces share the runner.
    private func runScenario(_ scenario: DemoScenario) {
        Task { @MainActor in
            await DemoScenarioRunner.run(
                scenario,
                chat: viewModel,
                sessions: sessionManager,
                registry: toolRegistry,
                sandboxRoot: sandboxRoot
            )
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

