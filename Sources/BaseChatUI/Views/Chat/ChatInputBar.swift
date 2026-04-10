import SwiftUI
import BaseChatCore

/// The text input bar at the bottom of the chat view.
///
/// Shows a multiline text field with send/stop buttons. On compact size class
/// (iPhone), a row of quick-action pills appears above the input for common
/// prompts like "Continue" and "Describe scene".
public struct ChatInputBar: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @FocusState private var isInputFocused: Bool

    public init() {}

    // MARK: - Body

    private var inputPlaceholder: String {
        if viewModel.isLoading { return "Loading model…" }
        if viewModel.activeSession == nil { return "No session selected" }
        if !viewModel.isModelLoaded { return "No model loaded" }
        return "Message…"
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 8) {
            if sizeClass == .compact {
                quickActionPills
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(inputPlaceholder, text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .padding(10)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isLoading)
                    .accessibilityLabel("Message input")

                actionButtons
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if showRegenerateButton {
                Button {
                    Task {
                        await viewModel.regenerateLastResponse()
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Regenerate last response")
                .help("Regenerate last response")
            }

            sendOrStopButton
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        SendStopButton(
            isGenerating: viewModel.isGenerating,
            canSend: canSend,
            onSend: sendMessage,
            onStop: { viewModel.stopGeneration() }
        )
    }

    // MARK: - Quick Action Pills

    private var quickActionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickActionPill("Continue") {
                    sendQuickAction("Continue")
                }
                quickActionPill("Summarize") {
                    sendQuickAction("Summarize")
                }
                quickActionPill("Explain more") {
                    sendQuickAction("Explain more")
                }
                quickActionPill("Give an example") {
                    sendQuickAction("Give an example")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func quickActionPill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.activeSession == nil || !viewModel.isModelLoaded || viewModel.isGenerating || viewModel.isLoading)
        .accessibilityLabel(title)
        .accessibilityHint("Sends \"\(title)\" as a message")
    }

    // MARK: - Helpers

    private var canSend: Bool {
        viewModel.activeSession != nil
        && viewModel.isModelLoaded
        && !viewModel.isGenerating
        && !viewModel.isLoading
        && !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showRegenerateButton: Bool {
        !viewModel.isGenerating
        && !viewModel.messages.isEmpty
        && viewModel.messages.last?.role == .assistant
    }

    private func sendMessage() {
        guard canSend else { return }
        Task {
            await viewModel.sendMessage()
        }
    }

    private func sendQuickAction(_ text: String) {
        viewModel.inputText = text
        Task {
            await viewModel.sendMessage()
        }
    }
}

// MARK: - Send/Stop Button

/// The primary send-or-stop button rendered at the trailing edge of the chat
/// input bar. Extracted as a standalone view so its accessibility contract can
/// be inspected in unit tests without mounting a full `ChatViewModel`.
struct SendStopButton: View {

    /// Accessibility label used while the assistant is generating a response.
    static let stopLabel = "Stop generation"
    /// Accessibility label used when the button will send the composed message.
    static let sendLabel = "Send message"

    let isGenerating: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    init(
        isGenerating: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isGenerating = isGenerating
        self.canSend = canSend
        self.onSend = onSend
        self.onStop = onStop
    }

    var body: some View {
        if isGenerating {
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.stopLabel)
            .help(Self.stopLabel)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Self.sendLabel)
            .help("\(Self.sendLabel) (Cmd+Return)")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()
        Divider()
        ChatInputBar()
    }
    .environment(ChatViewModel())
}
