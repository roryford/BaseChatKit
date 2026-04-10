import SwiftUI
import BaseChatCore

/// A compact banner that tells the user when older messages have been summarized
/// to fit the model's context window.
///
/// Appears near the top of the message list (next to the error banner region) only
/// when `stats` is non-nil. Tapping the banner reveals a small popover with the
/// strategy name, compression ratio, and estimated tokens after compression.
///
/// Visual language mirrors `ContextIndicatorView`: a small icon, a single line of
/// caption text, and a tinted rounded background that adapts to dark/light mode.
public struct CompressionIndicatorView: View {

    public let stats: CompressionStats

    @State private var isPopoverPresented = false

    public init(stats: CompressionStats) {
        self.stats = stats
    }

    // MARK: - Derived values

    private var compressedCount: Int {
        // How many original messages were folded away. Falls back to 0 if the
        // compressor somehow output more messages than it took in.
        max(0, stats.originalNodeCount - stats.outputMessageCount)
    }

    private var summary: String {
        "Older messages summarized · \(compressedCount) of \(stats.originalNodeCount) compressed"
    }

    private var a11yLabel: String {
        "\(compressedCount) older messages were summarized to fit the context window. Tap to view details."
    }

    private var ratioText: String {
        String(format: "%.1f×", stats.compressionRatio)
    }

    // MARK: - Body

    public var body: some View {
        Button {
            isPopoverPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "scissors")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)

                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isPopoverPresented) {
            detailPopover
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Detail Popover

    private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversation Summarized")
                .font(.headline)

            Text("Older turns were compressed so the latest context still fits the model's window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            LabeledContent("Strategy") {
                Text(stats.strategy.capitalized)
            }

            LabeledContent("Messages") {
                Text("\(stats.originalNodeCount) → \(stats.outputMessageCount)")
                    .monospacedDigit()
            }

            LabeledContent("Ratio") {
                Text(ratioText)
                    .monospacedDigit()
            }

            LabeledContent("Estimated tokens") {
                Text("\(stats.estimatedTokens)")
                    .monospacedDigit()
            }
        }
        .padding()
        .frame(minWidth: 260)
    }
}

// MARK: - Previews

#Preview("Extractive compression") {
    CompressionIndicatorView(
        stats: CompressionStats(
            strategy: "extractive",
            originalNodeCount: 12,
            outputMessageCount: 5,
            estimatedTokens: 800,
            compressionRatio: 2.4,
            keywordSurvivalRate: nil
        )
    )
    .padding()
}

#Preview("Anchored compression — heavy") {
    CompressionIndicatorView(
        stats: CompressionStats(
            strategy: "anchored",
            originalNodeCount: 48,
            outputMessageCount: 8,
            estimatedTokens: 1200,
            compressionRatio: 6.0,
            keywordSurvivalRate: nil
        )
    )
    .padding()
}
