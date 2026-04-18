import SwiftUI
import BaseChatCore
import BaseChatInference

/// Renders an array of ``MessagePart`` values within a message bubble.
///
/// Text parts are rendered inline (markdown for assistant, plain for user),
/// images are shown as thumbnails, and thinking blocks show a collapsible
/// disclosure group (or a streaming label while generation is in progress).
struct MessagePartsView: View {
    let parts: [MessagePart]
    let role: MessageRole
    var isStreaming: Bool = false

    var body: some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            partView(for: part)
        }
    }

    @ViewBuilder
    private func partView(for part: MessagePart) -> some View {
        switch part {
        case .text(let text):
            textView(text)

        case .image(let data, _):
            imageView(data)

        case .thinking(let text):
            // A thinking part with empty text is a streaming placeholder inserted
            // when the first .thinkingToken arrives; non-empty means the block was
            // finalized by .thinkingComplete. Using the text emptiness rather than
            // the overall isStreaming flag allows the disclosure group to appear
            // as soon as reasoning is complete, even while visible tokens are still
            // arriving.
            ThinkingBlockView(text: text, isThinkingStreaming: text.isEmpty && isStreaming)
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if role == .assistant {
            AssistantMarkdownView(content: text)
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(role == .user ? .white : .primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        #if os(iOS)
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        #endif
    }

}

#Preview("Text Only") {
    MessagePartsView(parts: [.text("Hello world")], role: .assistant)
}
