import SwiftUI
import BaseChatCore

enum MessageRenderingMode: Equatable {
    case plainText
    case markdown
}

enum MessageRenderingModeResolver {
    static func mode(for role: MessageRole) -> MessageRenderingMode {
        role == .assistant ? .markdown : .plainText
    }
}

struct AssistantMarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case markdown
        case code(language: String?)
    }

    let id: Int
    let kind: Kind
    let text: String
}

enum AssistantMarkdownParser {
    static func parseBlocks(from source: String) -> [AssistantMarkdownBlock] {
        guard !source.isEmpty else { return [] }

        let pattern = #"```([^\n`]*)\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [AssistantMarkdownBlock(id: 0, kind: .markdown, text: source)]
        }

        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return [AssistantMarkdownBlock(id: 0, kind: .markdown, text: source)]
        }

        var blocks: [AssistantMarkdownBlock] = []
        var nextID = 0
        var cursor = source.startIndex

        for match in matches {
            guard
                let matchRange = Range(match.range, in: source),
                let languageRange = Range(match.range(at: 1), in: source),
                let codeRange = Range(match.range(at: 2), in: source)
            else { continue }

            if cursor < matchRange.lowerBound {
                let markdownText = String(source[cursor..<matchRange.lowerBound])
                if !markdownText.isEmpty {
                    blocks.append(.init(id: nextID, kind: .markdown, text: markdownText))
                    nextID += 1
                }
            }

            let rawLanguage = source[languageRange].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLanguage = rawLanguage.isEmpty ? nil : rawLanguage
            let code = String(source[codeRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            blocks.append(.init(id: nextID, kind: .code(language: normalizedLanguage), text: code))
            nextID += 1

            cursor = matchRange.upperBound
        }

        if cursor < source.endIndex {
            let trailingText = String(source[cursor..<source.endIndex])
            if !trailingText.isEmpty {
                blocks.append(.init(id: nextID, kind: .markdown, text: trailingText))
            }
        }

        return blocks.isEmpty ? [AssistantMarkdownBlock(id: 0, kind: .markdown, text: source)] : blocks
    }

    static func attributedString(from markdown: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            return parsed
        }
        return AttributedString(markdown)
    }
}

struct AssistantMarkdownView: View {
    let content: String

    @State private var blocks: [AssistantMarkdownBlock]

    init(content: String) {
        self.content = content
        self._blocks = State(initialValue: AssistantMarkdownParser.parseBlocks(from: content))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .markdown:
                    Text(AssistantMarkdownParser.attributedString(from: block.text))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .code(let language):
                    AssistantCodeBlockView(code: block.text, language: language)
                }
            }
        }
        .onChange(of: content) {
            blocks = AssistantMarkdownParser.parseBlocks(from: content)
        }
    }
}

private struct AssistantCodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToClipboard(code)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code block")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
