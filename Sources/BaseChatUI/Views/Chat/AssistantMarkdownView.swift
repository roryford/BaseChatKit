import SwiftUI
import BaseChatCore

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
        var blocks: [AssistantMarkdownBlock] = []
        var nextID = 0
        var markdownBuffer = ""
        var codeBuffer = ""
        var isInCodeBlock = false
        var codeLanguage: String?
        var openingFenceLength = 0
        // Intentionally support markdown-in-markdown examples from LLM output.
        var nestedFenceDepth = 0

        let lines = source.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let hadTrailingNewline = lineIndex < lines.count - 1

            if !isInCodeBlock {
                if let fence = parseFenceLine(line) {
                    if !markdownBuffer.isEmpty {
                        blocks.append(.init(id: nextID, kind: .markdown, text: markdownBuffer))
                        nextID += 1
                        markdownBuffer = ""
                    }
                    isInCodeBlock = true
                    openingFenceLength = fence.ticks
                    codeLanguage = fence.rest.isEmpty ? nil : fence.rest
                    nestedFenceDepth = 0
                } else {
                    append(line: line, hadTrailingNewline: hadTrailingNewline, to: &markdownBuffer)
                }
                continue
            }

            if let fence = parseFenceLine(line), fence.ticks >= openingFenceLength {
                if fence.rest.isEmpty {
                    if nestedFenceDepth == 0 {
                        let code = codeBuffer.trimmingCharacters(in: .newlines)
                        blocks.append(.init(id: nextID, kind: .code(language: codeLanguage), text: code))
                        nextID += 1
                        codeBuffer = ""
                        isInCodeBlock = false
                        openingFenceLength = 0
                        codeLanguage = nil
                        continue
                    }
                    nestedFenceDepth -= 1
                } else {
                    nestedFenceDepth += 1
                }
            }

            append(line: line, hadTrailingNewline: hadTrailingNewline, to: &codeBuffer)
        }

        // Streaming can end mid-fence; keep partially parsed content as plain markdown.
        if isInCodeBlock {
            return [AssistantMarkdownBlock(id: 0, kind: .markdown, text: source)]
        }

        if !markdownBuffer.isEmpty {
            blocks.append(.init(id: nextID, kind: .markdown, text: markdownBuffer))
        }

        return blocks.isEmpty ? [AssistantMarkdownBlock(id: 0, kind: .markdown, text: source)] : blocks
    }

    private static func parseFenceLine(_ line: String) -> (ticks: Int, rest: String)? {
        // Accept arbitrary indentation to be lenient with streamed/model-formatted fences.
        let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLeading.first == "`" else { return nil }

        var tickCount = 0
        var index = trimmedLeading.startIndex
        while index < trimmedLeading.endIndex, trimmedLeading[index] == "`" {
            tickCount += 1
            index = trimmedLeading.index(after: index)
        }
        guard tickCount >= 3 else { return nil }

        let rest = String(trimmedLeading[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ticks: tickCount, rest: rest)
    }

    private static func append(line: String, hadTrailingNewline: Bool, to target: inout String) {
        target += line
        if hadTrailingNewline {
            target += "\n"
        }
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

#Preview("Plain Text") {
    AssistantMarkdownView(content: "Once upon a time in a land far away...")
}

#Preview("With Code Block") {
    AssistantMarkdownView(content: "Here's an example:\n\n```swift\nlet x = 42\nprint(x)\n```\n\nThat's how it works.")
}

#Preview("With Formatting") {
    AssistantMarkdownView(content: "This is **bold** and *italic* and a [link](https://example.com).")
}
