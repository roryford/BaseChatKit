import SwiftUI
import BaseChatCore
import BaseChatInference

/// Drop-in toolbar button that exports the active chat session via a
/// ``ConversationExportFormat`` and presents the system share sheet.
///
/// Reads the active session and messages off `ChatViewModel` in the
/// environment, so the button is a one-liner at the call site:
///
/// ```swift
/// .toolbar {
///     ExportButton(format: MarkdownExportFormat())
///     ExportButton(format: JSONLExportFormat())
/// }
/// ```
///
/// The export runs synchronously when the user taps; for large sessions
/// (>10k messages) a `Task` and a progress indicator may be more appropriate.
/// We keep this synchronous because the dominant cost is `ShareLink`'s own
/// sheet presentation, not the few-millisecond serialization.
public struct ExportButton<Format: ConversationExportFormat>: View {

    @Environment(ChatViewModel.self) private var viewModel

    private let format: Format
    private let label: String
    private let systemImage: String

    /// - Parameters:
    ///   - format: The serializer. Use ``MarkdownExportFormat`` or
    ///     ``JSONLExportFormat`` for the built-in formats, or pass a custom
    ///     ``ConversationExportFormat`` from your app.
    ///   - label: Visible text on the button. Defaults to "Export".
    ///   - systemImage: SF Symbol name. Defaults to `square.and.arrow.up`.
    public init(
        format: Format,
        label: String = "Export",
        systemImage: String = "square.and.arrow.up"
    ) {
        self.format = format
        self.label = label
        self.systemImage = systemImage
    }

    public var body: some View {
        if let file = makeShareableFile() {
            ShareLink(
                item: file.url,
                subject: Text(viewModel.activeSession?.title ?? "Chat"),
                message: Text("Exported from \(BaseChatConfiguration.shared.appName)"),
                preview: SharePreview(file.suggestedFilename)
            ) {
                Label(label, systemImage: systemImage)
            }
        } else {
            // Disabled placeholder when there's nothing to export — keeps
            // the toolbar layout stable across session switches.
            Button {
                // No-op
            } label: {
                Label(label, systemImage: systemImage)
            }
            .disabled(true)
        }
    }

    private func makeShareableFile() -> ShareableFile? {
        guard let session = viewModel.activeSession else { return nil }
        let messages = viewModel.messages
        guard !messages.isEmpty else { return nil }
        do {
            return try ConversationExporter.export(
                session: session,
                messages: messages,
                format: format
            )
        } catch {
            // Surfacing a banner from a SwiftUI computed body would loop
            // through `@State`; log and fall back to a disabled button.
            // Apps wanting richer error UX should call ``ConversationExporter``
            // directly from a button action instead of using this convenience.
            Log.ui.error("Conversation export failed: \(error.localizedDescription)")
            return nil
        }
    }
}
