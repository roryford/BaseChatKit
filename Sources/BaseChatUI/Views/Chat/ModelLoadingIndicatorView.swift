import SwiftUI

/// Loading indicator shown during model loading, with optional progress.
public struct ModelLoadingIndicatorView: View {
    public let progress: Double?

    public init(progress: Double? = nil) {
        self.progress = progress
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
            } else {
                ProgressView()
            }
            Text("Loading model…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading model, please wait")
    }
}
