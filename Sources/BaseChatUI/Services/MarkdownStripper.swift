import Foundation

/// Strips common Markdown formatting from text for speech synthesis.
///
/// Removes headers, emphasis, code blocks, links, and images so that
/// `AVSpeechSynthesizer` reads clean prose rather than markup characters.
public enum MarkdownStripper {

    /// Returns plain text with Markdown formatting removed.
    public static func strip(_ markdown: String) -> String {
        var text = markdown

        // Fenced code blocks: ```...``` (multiline)
        text = text.replacing(
            /```[\s\S]*?```/,
            with: ""
        )

        // Inline code: `code`
        text = text.replacing(/`([^`]+)`/) { match in
            String(match.output.1)
        }

        // Images: ![alt](url)
        text = text.replacing(/!\[([^\]]*)\]\([^)]+\)/) { match in
            String(match.output.1)
        }

        // Links: [text](url)
        text = text.replacing(/\[([^\]]+)\]\([^)]+\)/) { match in
            String(match.output.1)
        }

        // Headers: # Header → Header
        text = text.replacing(/(?m)^#{1,6}\s+/, with: "")

        // Bold + italic: ***text*** or ___text___
        text = text.replacing(/(\*{3}|_{3})(.+?)\1/) { match in
            String(match.output.2)
        }

        // Bold: **text** or __text__
        text = text.replacing(/(\*{2}|_{2})(.+?)\1/) { match in
            String(match.output.2)
        }

        // Italic: *text* or _text_
        text = text.replacing(/(\*|_)(.+?)\1/) { match in
            String(match.output.2)
        }

        // Strikethrough: ~~text~~
        text = text.replacing(/~~(.+?)~~/) { match in
            String(match.output.1)
        }

        // Blockquotes: > text → text
        text = text.replacing(/(?m)^>\s?/, with: "")

        // Horizontal rules: ---, ***, ___
        text = text.replacing(/(?m)^[-*_]{3,}\s*$/, with: "")

        // Unordered list markers: - item, * item, + item
        text = text.replacing(/(?m)^[\s]*[-*+]\s+/, with: "")

        // Ordered list markers: 1. item
        text = text.replacing(/(?m)^[\s]*\d+\.\s+/, with: "")

        // Collapse multiple blank lines
        text = text.replacing(/\n{3,}/, with: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
