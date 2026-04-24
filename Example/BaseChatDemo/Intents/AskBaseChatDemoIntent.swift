import AppIntents
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// App Intent that routes a prompt from Spotlight, Siri, or Shortcuts
/// into a fresh chat session inside the demo app.
///
/// ## How it works
///
/// 1. The intent writes a JSON-encoded payload into the shared App Group
///    `UserDefaults` (`group.com.basechatkit.demo`, key `bck.inbound`).
/// 2. It then opens the app via the `basechatdemo://ingest` URL scheme.
/// 3. The app's `.onOpenURL` handler reads the payload back out and
///    calls ``ChatViewModel/ingest(_:)`` directly, or buffers it via
///    ``PendingPayloadBuffer`` if the persistence container hasn't
///    finished wiring yet.
///
/// The intent lives in the main app target — App Intents on iOS 17+ and
/// macOS 14+ are discovered at runtime via ``AppShortcutsProvider`` and
/// do not require a separate extension target.
public struct AskBaseChatDemoIntent: AppIntent {

    public static let title: LocalizedStringResource = "Ask BaseChat Demo"

    public static let description = IntentDescription(
        "Sends a prompt to BaseChat Demo and opens the app with a fresh chat session.",
        categoryName: "Chat"
    )

    /// Route the result through the app's foreground scene so the user
    /// lands in the chat session the prompt seeded.
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "What would you like to ask BaseChat Demo?")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        // Serialize to App Group storage so the main app can retrieve the
        // payload after the scheme-deep-link hits. We encode a minimal
        // envelope rather than the full `InboundPayload` struct because
        // `InboundPayload` is not `Codable` — attachments carry
        // `MessagePart` values that already have their own
        // persistence-oriented codable story we don't need here.
        let envelope = InboundPayloadEnvelope(prompt: prompt, source: "appIntent")
        if let defaults = UserDefaults(suiteName: DemoAppGroup.identifier) {
            if let encoded = try? JSONEncoder().encode(envelope) {
                defaults.set(encoded, forKey: DemoAppGroup.inboundKey)
            }
        }

        // Open via the custom URL scheme. The app's `.onOpenURL` handler
        // is responsible for actually draining the App Group defaults —
        // this intent only signals that a payload is waiting.
        let url = URL(string: "basechatdemo://ingest")!
        #if canImport(UIKit)
        await UIApplication.shared.open(url, options: [:])
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif

        return .result()
    }
}

/// JSON envelope written to App Group defaults.
///
/// Defined alongside the intent so both the write (here) and the read
/// (in `BaseChatDemoApp.onOpenURL`) share one shape. Codable rather than
/// piggybacking on `InboundPayload` because the struct carries
/// non-Codable attachments — we keep this envelope text-only today and
/// can add an `attachments: [MessagePart]` field later when a richer
/// source starts using it.
struct InboundPayloadEnvelope: Codable, Sendable {
    var prompt: String
    var source: String
}

/// App Group identifier shared between the intent (writer) and the
/// app's `.onOpenURL` handler (reader). Centralised so renaming stays
/// in one place.
enum DemoAppGroup {
    static let identifier = "group.com.basechatkit.demo"
    static let inboundKey = "bck.inbound"
}
