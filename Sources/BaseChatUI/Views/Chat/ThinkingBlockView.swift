import SwiftUI

/// A collapsible disclosure group displaying model reasoning content.
///
/// Shows a "Thinking…" label while streaming (no text dump during active reasoning)
/// and a disclosure triangle labelled "Reasoning" once the block is complete.
struct ThinkingBlockView: View {
    let text: String
    let isStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        if isStreaming {
            Label("Thinking…", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Completed") {
    ThinkingBlockView(
        text: "Let me think about this step by step. First I'll consider the constraints...",
        isStreaming: false
    )
    .padding()
}

#Preview("Streaming") {
    ThinkingBlockView(text: "", isStreaming: true)
        .padding()
}
