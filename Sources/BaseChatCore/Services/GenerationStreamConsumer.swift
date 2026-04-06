import Foundation

/// Transforms raw ``GenerationEvent`` values into UI-actionable commands.
///
/// Extracted from `ChatViewModel+Generation` so the event→action mapping
/// can be tested without SwiftData, `@MainActor`, or any UI state.
public struct GenerationStreamConsumer: Sendable {

    /// Whether to check for repetitive looping in appended text.
    public var loopDetectionEnabled: Bool

    /// Running character count of appended text, used for loop detection threshold.
    private var appendedCharacterCount: Int = 0

    public init(loopDetectionEnabled: Bool = true) {
        self.loopDetectionEnabled = loopDetectionEnabled
    }

    /// Processes a single generation event and returns the action the caller should take.
    public mutating func handle(_ event: GenerationEvent) -> StreamAction {
        switch event {
        case .token(let text):
            appendedCharacterCount += text.count
            return .appendText(text)

        case .usage(let prompt, let completion):
            return .recordUsage(prompt: prompt, completion: completion)

        case .toolCall:
            return .noOp
        }
    }

    /// Checks whether the accumulated content looks like a repetition loop.
    ///
    /// Call this after processing `.appendText` actions once enough content
    /// has been accumulated (the caller decides the threshold).
    public func shouldStopForLoop(content: String) -> Bool {
        guard loopDetectionEnabled else { return false }
        guard content.count >= 100 else { return false }
        return RepetitionDetector.looksLikeLooping(content)
    }

    /// Actions the caller should take in response to a generation event.
    public enum StreamAction: Equatable, Sendable {
        /// Append the text to the current assistant message.
        case appendText(String)
        /// Record token usage on the current assistant message.
        case recordUsage(prompt: Int, completion: Int)
        /// No action needed for this event.
        case noOp
    }
}
