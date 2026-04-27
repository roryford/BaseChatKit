import Foundation

/// Codable payload written to the App Group container by Share and Action
/// Extensions and drained by the host app on the next foreground transition.
///
/// This type is intentionally **pure Foundation** — no BaseChatKit dependency
/// — so it can be compiled into both the host app and the lightweight
/// extension targets, which must stay under the iOS extension memory budget.
///
/// ## Wire format
///
/// Extensions write a JSON-encoded `PendingSharePayload` to:
/// - App Group: `group.com.basechatkit.demo`
/// - Key: `bck.pending-share`
///
/// The host app reads it in ``BaseChatDemoApp/checkForPendingSharePayload()``
/// and converts it to a ``PendingPayload`` before calling
/// ``ChatViewModel/ingestPendingPayload(_:intent:)``.
///
/// ## Payload priority
///
/// If the extension finds multiple item types, it picks the best one in this
/// order: URL > plain text > image.  Only one payload is queued per extension
/// invocation.
struct PendingSharePayload: Codable, Sendable {

    /// The flavour of content the extension captured.
    enum Kind: String, Codable {
        case text
        case url
        case image
    }

    /// The flavour of content this payload carries.
    var kind: Kind

    /// Plain-text body — populated when `kind == .text`.
    var text: String?

    /// Absolute string of the shared URL — populated when `kind == .url`.
    var urlString: String?

    /// Raw image bytes — populated when `kind == .image`.
    var imageData: Data?

    /// MIME type for `imageData`; defaults to `"image/png"` at the read site
    /// when absent.
    var imageMimeType: String?

    /// Entry point that produced this payload.
    ///
    /// - `"shareExtension"`: iOS/macOS Share sheet
    /// - `"actionExtension"`: iOS Action sheet ("Summarise selection")
    var source: String
}
