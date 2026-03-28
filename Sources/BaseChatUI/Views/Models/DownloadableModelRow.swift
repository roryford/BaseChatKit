import SwiftUI
import BaseChatCore

/// A row displaying a downloadable model with compatibility badge and download controls.
///
/// Shows the model name, size, description, and a contextual action: download button,
/// progress indicator, or "Downloaded" badge depending on the model's current state.
public struct DownloadableModelRow: View {

    public let model: DownloadableModel

    @Environment(ModelManagementViewModel.self) private var viewModel

    public init(model: DownloadableModel) {
        self.model = model
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            compatibilityBadge
                .accessibilityLabel(compatibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(model.sizeFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.isCurated {
                        Text("Curated")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Curated model")
                    }
                }

                if let description = model.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            trailingContent
        }
        .padding(.vertical, 4)
    }

    // MARK: - Compatibility Badge

    /// Colored circle indicating whether this device can run the model.
    @ViewBuilder
    private var compatibilityBadge: some View {
        let canRun = viewModel.canRunModel(sizeBytes: model.sizeBytes)
        let isBorderline = !canRun && viewModel.canRunModel(sizeBytes: model.sizeBytes * 80 / 100)

        Circle()
            .fill(badgeColor(canRun: canRun, isBorderline: isBorderline))
            .frame(width: 10, height: 10)
            .padding(.top, 6)
    }

    private func badgeColor(canRun: Bool, isBorderline: Bool) -> Color {
        if canRun { return .green }
        if isBorderline { return .yellow }
        return .red
    }

    private var compatibilityLabel: String {
        let canRun = viewModel.canRunModel(sizeBytes: model.sizeBytes)
        if canRun { return "Compatible with this device" }
        return "May be too large for this device"
    }

    // MARK: - Trailing Content (Download/Progress/Badge)

    @ViewBuilder
    private var trailingContent: some View {
        if viewModel.isModelDownloaded(model) {
            downloadedBadge
        } else if let state = viewModel.downloadState(for: model) {
            DownloadProgressView(state: state)
        } else {
            downloadButton
        }
    }

    private var downloadedBadge: some View {
        Label("Downloaded", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
    }

    private var downloadButton: some View {
        Button {
            viewModel.startDownload(model)
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download \(model.displayName)")
        .accessibilityHint("Downloads \(model.sizeFormatted) model to this device")
    }
}

// MARK: - Preview

#Preview {
    List {
        DownloadableModelRow(
            model: DownloadableModel(
                repoID: "bartowski/Mistral-7B-Instruct-v0.3-GGUF",
                fileName: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
                displayName: "Mistral 7B Instruct v0.3",
                modelType: .gguf,
                sizeBytes: 4_100_000_000,
                isCurated: true,
                description: "Balanced 7B model, good storytelling quality"
            )
        )
    }
    .environment(ModelManagementViewModel())
}
