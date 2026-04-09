import SwiftUI
import BaseChatCore

/// A single chat message rendered as a bubble.
///
/// User messages are right-aligned with accent coloring, assistant messages
/// are left-aligned with a secondary background, and system messages are
/// centered and italic. Supports streaming state with a pulsing indicator.
/// When `isPinned` is `true`, a small pin icon is shown in the top-trailing
/// corner of the bubble to indicate the message is preserved from compression.
public struct MessageBubbleView: View {

    public let message: ChatMessageRecord
    public let isStreaming: Bool
    public let isPinned: Bool

    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(message: ChatMessageRecord, isStreaming: Bool, isPinned: Bool = false) {
        self.message = message
        self.isStreaming = isStreaming
        self.isPinned = isPinned
    }

    // MARK: - Body

    public var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: spacerMinLength) }

            bubbleContent
                .frame(maxWidth: 700, alignment: alignment)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(message.role.rawValue): \(message.content)")

            if message.role == .assistant { Spacer(minLength: spacerMinLength) }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .padding(.horizontal)
        .padding(.vertical, 2)
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .system:
            systemBubble
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        }
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessagePartsView(parts: message.contentParts, role: .user)

            timestampLabel
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(12)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.contentParts.isEmpty && isStreaming {
                streamingPlaceholder
            } else {
                MessagePartsView(parts: message.contentParts, role: .assistant)
            }

            if isStreaming && !message.contentParts.isEmpty {
                streamingIndicator
            }

            if !isStreaming || !message.contentParts.isEmpty {
                HStack(spacing: 6) {
                    timestampLabel
                        .foregroundStyle(.secondary)

                    if let completion = message.completionTokens {
                        Text("\(completion) tokens")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            pinIndicator
        }
    }

    private var systemBubble: some View {
        VStack(spacing: 4) {
            Text(message.content)
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            timestampLabel
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pin Indicator

    @ViewBuilder
    private var pinIndicator: some View {
        if isPinned {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
                .accessibilityLabel("Pinned message")
        }
    }

    // MARK: - Streaming Indicator

    private var streamingPlaceholder: some View {
        TypingIndicatorView()
            .padding(.vertical, 4)
    }

    private var streamingIndicator: some View {
        StreamingCursorView()
            .accessibilityLabel("Still generating")
    }

    // MARK: - Timestamp

    private var timestampLabel: some View {
        Text(message.timestamp, style: .time)
            .font(.caption)
    }

    // MARK: - Layout Helpers

    private var alignment: Alignment {
        switch message.role {
        case .user: .trailing
        case .assistant: .leading
        case .system: .center
        }
    }

    /// The minimum spacer length determines maximum bubble width.
    /// On compact (iPhone), bubbles take ~90% width; on regular (iPad/Mac), ~80%.
    private var spacerMinLength: CGFloat {
        sizeClass == .compact ? 20 : 60
    }
}

// MARK: - Preview

#Preview("User Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .user, content: "Hello, tell me a story about a dragon.", sessionID: UUID()),
        isStreaming: false
    )
}

#Preview("Assistant Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .assistant, content: "Once upon a time, in a land far away, there lived a magnificent dragon named Ember.", sessionID: UUID()),
        isStreaming: false
    )
}

#Preview("Assistant Streaming") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .assistant, content: "Once upon a time...", sessionID: UUID()),
        isStreaming: true
    )
}

#Preview("System Message") {
    MessageBubbleView(
        message: ChatMessageRecord(role: .system, content: "You are a creative storytelling assistant.", sessionID: UUID()),
        isStreaming: false
    )
}
