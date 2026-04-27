import UIKit
import UniformTypeIdentifiers

// App Group constants — mirror DemoAppGroup (host app). Duplicated because
// the extension cannot import InboundPayloadEnvelope (BaseChatInference dep).
private let kAppGroupID = "group.com.basechatkit.demo"
private let kPendingKey = "bck.pending-share"

/// Action Extension principal class — "Summarise selection" recipe.
///
/// Captures selected text (or a URL) from the host app, serialises it as a
/// ``PendingSharePayload`` into the shared App Group container, and completes
/// the request. The host app ingests the payload on next foreground
/// activation via ``BaseChatDemoApp/checkForPendingSharePayload()``.
///
/// ## Usage
///
/// Users invoke the extension via the Action sheet in any app that exposes
/// selected text (Safari Reader, Notes, Mail, etc.). The extension writes the
/// selection and immediately completes — no UI is shown. The next time the
/// user switches to BaseChat Demo, the selection is opened in a new session
/// seeded with the text, ready for the model to summarise.
///
/// ## No inference in the extension
///
/// This file imports nothing from BaseChatKit. The only non-system dependency
/// is ``PendingSharePayload``.
class ActionViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            await handleItems()
        }
    }

    private func handleItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let payload = await extractPayload(from: items)

        if let payload,
           let defaults = UserDefaults(suiteName: kAppGroupID),
           let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: kPendingKey)
        }

        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Item extraction

    // Action extensions receive selected text or URLs. Text wins over URL
    // because the typical "summarise selection" recipe captures prose.
    private func extractPayload(from items: [NSExtensionItem]) async -> PendingSharePayload? {
        for item in items {
            for provider in (item.attachments ?? []) {
                if let payload = await loadText(from: provider) { return payload }
                if let payload = await loadURL(from: provider) { return payload }
            }
        }
        return nil
    }

    private func loadText(from provider: NSItemProvider) async -> PendingSharePayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        guard let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
              !text.isEmpty else { return nil }
        return PendingSharePayload(kind: .text, text: text, source: "actionExtension")
    }

    private func loadURL(from provider: NSItemProvider) async -> PendingSharePayload? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        guard let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL else {
            return nil
        }
        return PendingSharePayload(kind: .url, urlString: url.absoluteString, source: "actionExtension")
    }
}
