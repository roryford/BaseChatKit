import Foundation

/// A ``TokenizerProvider`` that estimates token count using ~4 characters per token.
///
/// This matches the heuristic already used by ``ContextWindowManager`` and is suitable
/// as a fallback when no model-specific tokenizer is available.
package struct HeuristicTokenizer: TokenizerProvider {
    package init() {}

    package func tokenCount(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
