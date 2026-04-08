import SwiftUI
import BaseChatCore

/// Renders an array of ``MessagePart`` values within a message bubble.
///
/// Text parts are rendered inline (markdown for assistant, plain for user),
/// images are shown as thumbnails, and tool calls/results are displayed as
/// labeled disclosure groups.
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

        case .toolCall(let id, let name, let arguments):
            toolCallView(id: id, name: name, arguments: arguments)

        case .toolResult(let id, let content):
            toolResultView(id: id, content: content)
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

    private func toolCallView(id: String, name: String, arguments: String) -> some View {
        DisclosureGroup {
            Text(arguments)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(name, systemImage: "wrench")
                .font(.callout.bold())
        }
        .padding(8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolResultView(id: String, content: String) -> some View {
        DisclosureGroup {
            Text(content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tool Result", systemImage: "arrow.turn.down.left")
                .font(.callout.bold())
        }
        .padding(8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview("Text Only") {
    MessagePartsView(parts: [.text("Hello world")], role: .assistant)
}

#Preview("Tool Call") {
    MessagePartsView(parts: [.toolCall(id: "1", name: "get_weather", arguments: "{\"city\": \"London\"}")], role: .assistant)
}

#Preview("Mixed Parts") {
    MessagePartsView(parts: [.text("Check this:"), .toolResult(id: "1", content: "Temperature: 18°C")], role: .user)
}
