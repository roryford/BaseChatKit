import SwiftUI
import BaseChatUI

/// Flagship empty-state shown in the chat detail area when the active session
/// has no messages yet.
///
/// The "Summarize the README files in my workspace." prompt drives the
/// scripted repo-search tool, which exercises: thinking stream (if the model
/// supports it) → tool call → approval sheet → tool result rendering →
/// assistant synthesis. It's the single tap that takes a reviewer through the
/// whole differentiator loop in one go.
struct ChatEmptyStateView: View {

    @Environment(ChatViewModel.self) private var viewModel

    private static let flagshipPrompt = "Summarize the README files in my workspace."

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tint)

            Text("Try the flagship prompt")
                .font(.headline)

            Text("Kicks off thinking, a tool call for README summarisation, and an approval sheet — the full BaseChatKit loop in one tap.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                sendFlagshipPrompt()
            } label: {
                Label(Self.flagshipPrompt, systemImage: "paperplane.fill")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("flagship-prompt-button")
            .disabled(!viewModel.isModelLoaded)
        }
        .padding(.vertical, 32)
    }

    private func sendFlagshipPrompt() {
        viewModel.inputText = Self.flagshipPrompt
        Task { await viewModel.sendMessage() }
    }
}
