import Foundation
import BaseChatInference

/// Centralized factory for URLSession instances used by cloud backends.
///
/// Eliminates the duplicated `static let pinnedSession` blocks that each
/// backend previously maintained with subtly different timeout configs.
/// All backends continue to accept a `urlSession:` init parameter for
/// test injection via `MockURLProtocol`.
public enum URLSessionProvider {

    /// Session with ``PinnedSessionDelegate`` for production API hosts.
    ///
    /// Shared by OpenAI and Claude backends. Certificate pinning
    /// is enforced for `api.openai.com` and `api.anthropic.com`; custom hosts
    /// fall through to default trust evaluation.
    public static let pinned: URLSession = {
        PinnedSessionDelegate.loadDefaultPins()
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Session without certificate pinning for LAN servers (Ollama, local endpoints).
    ///
    /// Appropriate for servers discovered via Bonjour or configured with
    /// private/local IP addresses where TLS pinning is not applicable.
    public static let unpinned: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()
}
