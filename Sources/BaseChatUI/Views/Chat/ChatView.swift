import SwiftUI
import BaseChatCore

/// The main chat view, displayed in the detail area of the app's navigation structure.
///
/// Shows a scrolling message history with auto-scroll, an input bar at the
/// bottom, and toolbar actions for device info, settings, and clearing the chat.
public struct ChatView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(NarrationViewModel.self) private var narrationViewModel: NarrationViewModel?

    private var features: BaseChatConfiguration.Features { BaseChatConfiguration.shared.features }

    /// Controls the model management sheet. Passed in from the host app so that the
    /// "Browse Models" button in the empty state can open it directly.
    @Binding public var showModelManagement: Bool

    @State private var isDeviceInfoExpanded: Bool = false
    @State private var isSettingsPresented: Bool = false
    @State private var isExportPresented: Bool = false
    @State private var showClearConfirmation: Bool = false

    public init(showModelManagement: Binding<Bool>) {
        self._showModelManagement = showModelManagement
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            errorBanner

            if viewModel.isLoading {
                loadingView
            } else if !viewModel.isModelLoaded {
                noModelLoadedView
            } else {
                messageList
            }

            if features.showUpgradeHint && viewModel.showUpgradeHint {
                upgradeHintBanner
            }

            if let narration = narrationViewModel,
               features.showNarration,
               narration.state != .idle {
                narrationPlaybackBar(narration: narration)
            }

            Divider()
                .accessibilityHidden(true)

            ChatInputBar()
        }
        .navigationTitle("Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if let backend = viewModel.activeBackendName,
                   ["OpenAI", "Claude", "Ollama", "LM Studio"].contains(backend) {
                    Label("Cloud", systemImage: "cloud.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("Using cloud backend: \(backend)")
                }
                if features.showContextIndicator {
                    ContextIndicatorView(
                        usedTokens: viewModel.contextUsedTokens,
                        maxTokens: viewModel.contextMaxTokens
                    )
                }
                if features.showMemoryIndicator {
                    MemoryIndicatorView(
                        pressureLevel: viewModel.memoryPressureLevel,
                        physicalMemoryBytes: viewModel.physicalMemoryBytes,
                        appMemoryBytes: viewModel.appMemoryUsageBytes
                    )
                }
                if features.showChatExport {
                    exportButton
                }
                deviceInfoButton
                if features.showGenerationSettings {
                    settingsButton
                }
                clearChatButton
            }
        }
        .alert("Clear Chat", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                viewModel.clearChat()
            }
        } message: {
            Text("This will delete all messages in the current chat. This cannot be undone.")
        }
        .sheet(isPresented: $isSettingsPresented) {
            GenerationSettingsView()
        }
        .sheet(isPresented: $isExportPresented) {
            ChatExportSheet()
        }
    }

    // MARK: - Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)

                Text(error)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    viewModel.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(12)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    // MARK: - Upgrade Hint Banner

    private var upgradeHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            Text("Want longer responses? Download a model for extended context.")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showModelManagement = true
            } label: {
                Text("Browse")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
            .accessibilityLabel("Browse models for extended context")
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Setting things up...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setting things up, please wait")
    }

    // MARK: - No Model Loaded

    @ViewBuilder
    private var noModelLoadedView: some View {
        if viewModel.availableModels.isEmpty {
            // No models at all — welcome screen with browse CTA
            VStack(spacing: 20) {
                Image(systemName: "book.and.wrench")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text("Welcome to \(BaseChatConfiguration.shared.appName)")
                        .font(.title2.bold())

                    Text("Download a model to get started, or connect a cloud API in settings.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button {
                    showModelManagement = true
                } label: {
                    Label("Browse Models", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Browse and download models")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            // Models exist but none is selected
            ContentUnavailableView {
                Label("No Model Selected", systemImage: "cpu")
            } description: {
                Text("Select a model from the sidebar to start chatting.")
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if viewModel.messages.isEmpty && !viewModel.isGenerating {
                        emptyPlaceholder
                    }

                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(
                            message: message,
                            isStreaming: isMessageStreaming(message),
                            isPinned: viewModel.isMessagePinned(id: message.id)
                        )
                        .messageActionMenu(message: message, viewModel: viewModel)
                        .id(message.id)
                    }

                    // Invisible anchor for auto-scrolling.
                    Color.clear
                        .frame(height: 1)
                        .id("chatBottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.messages.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) {
                scrollToBottom(proxy: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyPlaceholder: some View {
        Text("Send a message to start chatting.")
            .foregroundStyle(.tertiary)
            .font(.body)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    // MARK: - Toolbar Items

    private var exportButton: some View {
        Button {
            isExportPresented = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(viewModel.messages.isEmpty)
        .accessibilityLabel("Export chat")
    }

    private var deviceInfoButton: some View {
        Button {
            isDeviceInfoExpanded.toggle()
        } label: {
            Label("Device Info", systemImage: "info.circle")
        }
        .popover(isPresented: $isDeviceInfoExpanded) {
            deviceInfoPopover
        }
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Label("Settings", systemImage: "gear")
        }
        .accessibilityLabel("Generation settings")
    }

    private var clearChatButton: some View {
        Button {
            showClearConfirmation = true
        } label: {
            Label("Clear Chat", systemImage: "trash")
        }
        .disabled(viewModel.messages.isEmpty)
        .accessibilityLabel("Clear chat")
    }

    // MARK: - Device Info Popover

    private var deviceInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Info")
                .font(.headline)

            LabeledContent("Device") {
                Text(viewModel.deviceDescription)
            }

            LabeledContent("Recommended Size") {
                Text(viewModel.recommendedSize.description)
            }

            LabeledContent("Model Loaded") {
                Text(viewModel.isModelLoaded ? "Yes" : "No")
                    .foregroundStyle(viewModel.isModelLoaded ? .green : .secondary)
            }
            .accessibilityValue(viewModel.isModelLoaded ? "Yes" : "No")

            if let backend = viewModel.activeBackendName {
                LabeledContent("Backend") {
                    Text(backend)
                }
            }
        }
        .padding()
        .frame(minWidth: 280)
    }

    // MARK: - Narration Playback Bar

    private func narrationPlaybackBar(narration: NarrationViewModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("Reading aloud")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case .speaking = narration.state {
                Button { narration.pause() } label: {
                    Image(systemName: "pause.fill")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause narration")
            } else if case .paused = narration.state {
                Button { narration.resume() } label: {
                    Image(systemName: "play.fill")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Resume narration")
            }

            Button { narration.stopAll() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop narration")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.fill.quaternary)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Helpers

    private func isMessageStreaming(_ message: ChatMessageRecord) -> Bool {
        viewModel.isGenerating
        && message.role == .assistant
        && message.id == viewModel.messages.last?.id
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("chatBottom", anchor: .bottom)
        }
    }
}

// MARK: - Preview

#Preview("Chat View") {
    NavigationStack {
        ChatView(showModelManagement: .constant(false))
    }
    .environment(ChatViewModel())
}
