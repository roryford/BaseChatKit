import SwiftUI
import BaseChatCore

/// Shows context window usage as a compact gauge in the chat toolbar.
///
/// Changes color based on usage: green (< 80%), yellow (80-95%), red (> 95%).
public struct ContextIndicatorView: View {

    public let usedTokens: Int
    public let maxTokens: Int

    public init(usedTokens: Int, maxTokens: Int) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
    }

    private var ratio: Double {
        guard maxTokens > 0 else { return 0 }
        return Double(usedTokens) / Double(maxTokens)
    }

    private var color: Color {
        if ratio >= 0.95 { return .red }
        if ratio >= 0.80 { return .yellow }
        return .green
    }

    private var percentage: Int {
        Int(min(ratio * 100, 999))
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Mini progress ring
            ZStack {
                Circle()
                    .stroke(.tertiary, lineWidth: 2)

                Circle()
                    .trim(from: 0, to: min(ratio, 1.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)

            Text("\(percentage)%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(ratio >= 0.80 ? color : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .help("Context: \(usedTokens) / \(maxTokens) tokens (\(percentage)%)")
        .accessibilityLabel("Context usage \(percentage) percent, \(usedTokens) of \(maxTokens) tokens")
    }
}

#Preview("Low usage") {
    ContextIndicatorView(usedTokens: 500, maxTokens: 4096)
}

#Preview("High usage") {
    ContextIndicatorView(usedTokens: 3500, maxTokens: 4096)
}

#Preview("Critical") {
    ContextIndicatorView(usedTokens: 3900, maxTokens: 4096)
}
