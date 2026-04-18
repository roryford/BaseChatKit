import SwiftUI

/// A collapsible disclosure group displaying model reasoning content.
///
/// Shows a "Thinking…" label while `isThinkingStreaming` is true (reasoning is
/// still in progress) and a disclosure triangle labelled "Reasoning" once the
/// block is finalized. This is intentionally decoupled from the overall message
/// streaming flag — completed reasoning should become expandable even while
/// visible tokens are still arriving.
struct ThinkingBlockView: View {
    let text: String
    /// True only while the reasoning block itself is still open (i.e. no
    /// `.thinkingComplete` event has been received yet). Distinct from the
    /// overall message `isStreaming` flag.
    let isThinkingStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        if isThinkingStreaming {
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
        isThinkingStreaming: false
    )
    .padding()
}

#Preview("Streaming") {
    ThinkingBlockView(text: "", isThinkingStreaming: true)
        .padding()
}
