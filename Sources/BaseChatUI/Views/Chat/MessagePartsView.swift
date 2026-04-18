import SwiftUI
import BaseChatCore
import BaseChatInference

/// Renders an array of ``MessagePart`` values within a message bubble.
///
/// Text parts are rendered inline (markdown for assistant, plain for user)
/// and images are shown as thumbnails.
struct MessagePartsView: View {
    let parts: [MessagePart]
    let role: MessageRole

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

        case .thinking:
            // Thinking parts are not rendered inline in the default message view.
            // Phase 2 will add a dedicated thinking disclosure UI.
            EmptyView()
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
