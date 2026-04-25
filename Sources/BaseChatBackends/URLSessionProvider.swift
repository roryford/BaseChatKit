import Foundation
import BaseChatInference

/// Centralized factory for URLSession instances used by cloud backends.
///
/// Eliminates the duplicated `static let pinnedSession` blocks that each
/// backend previously maintained with subtly different timeout configs.
/// All backends continue to accept a `urlSession:` init parameter for
/// test injection via `MockURLProtocol`.
///
/// ## Trait gating
///
/// The factories are conditionally compiled:
/// - ``pinned`` / ``pinned()`` are only available with the `CloudSaaS` trait —
///   no SaaS backend means no pinning is needed.
/// - ``unpinned`` / ``unpinned()`` are available whenever `Ollama` or
///   `CloudSaaS` is enabled — used by Ollama (LAN) and as the LM-Studio /
///   `.custom` provider session under `CloudSaaS`.
///
/// The ``networkDisabled`` runtime kill-switch is always available so
/// embedders can lock the network even in a `full`-trait build.
///
/// ## Two accessor flavours
///
/// Each session has two accessors:
/// - A non-throwing static property (``pinned``, ``unpinned``) that traps if
///   the kill-switch is set at first access. This is the legacy ergonomic API
///   used by every cloud backend's `init(urlSession:)` and by the bulk of the
///   test suite.
/// - A throwing function (``throwingPinned()``, ``throwingUnpinned()``) that
///   surfaces the kill-switch as a recoverable
///   ``CloudBackendError/networkDisabled`` error. Use this from embedders
///   that flip the kill-switch dynamically and from tests that exercise the
///   failure path.
public enum URLSessionProvider {

    /// Belt-and-suspenders runtime kill-switch. When `true`, the throwing
    /// factories (``throwingPinned()``, ``throwingUnpinned()``) throw
    /// ``CloudBackendError/networkDisabled`` rather than returning a session;
    /// the non-throwing accessors trap with a precondition for the same
    /// reason. Useful for a regulated runtime that wants to lock network
    /// even in a `full`-trait build.
    ///
    /// Defaults to `false`. Set at app startup if needed; flipping it after
    /// sessions are already cached only affects callers that obtain a fresh
    /// session via the throwing factories below.
    ///
    /// `nonisolated(unsafe)` matches the project pattern for boot-time
    /// configuration flags (see `DNSRebindingGuard._resolverForTesting`):
    /// callers are expected to write this once at app startup before any
    /// concurrent reader can observe it.
    public nonisolated(unsafe) static var networkDisabled: Bool = false

    #if CloudSaaS
    /// Cached session shared by all SaaS backends — created once on first call.
    private static let _pinned: URLSession = {
        PinnedSessionDelegate.loadDefaultPins()
        let delegate = PinnedSessionDelegate()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    /// Session with ``PinnedSessionDelegate`` for production API hosts.
    ///
    /// Shared by OpenAI and Claude backends. Certificate pinning
    /// is enforced for `api.openai.com` and `api.anthropic.com`; custom hosts
    /// fall through to default trust evaluation.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`.
    ///   Use ``throwingPinned()`` for a throwing variant.
    public static var pinned: URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingPinned() instead.")
        return _pinned
    }

    /// Throwing accessor for the pinned session — surfaces the runtime
    /// kill-switch as a recoverable error.
    ///
    /// - Throws: ``CloudBackendError/networkDisabled`` when ``networkDisabled``
    ///   is `true`.
    public static func throwingPinned() throws -> URLSession {
        if networkDisabled {
            throw CloudBackendError.networkDisabled
        }
        return _pinned
    }
    #endif

    #if Ollama || CloudSaaS
    /// Cached session shared by LAN / unpinned callers.
    private static let _unpinned: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Session without certificate pinning for LAN servers (Ollama, local endpoints).
    ///
    /// Appropriate for servers discovered via Bonjour or configured with
    /// private/local IP addresses where TLS pinning is not applicable.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`.
    ///   Use ``throwingUnpinned()`` for a throwing variant.
    public static var unpinned: URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingUnpinned() instead.")
        return _unpinned
    }

    /// Throwing accessor for the unpinned session — surfaces the runtime
    /// kill-switch as a recoverable error.
    ///
    /// - Throws: ``CloudBackendError/networkDisabled`` when ``networkDisabled``
    ///   is `true`.
    public static func throwingUnpinned() throws -> URLSession {
        if networkDisabled {
            throw CloudBackendError.networkDisabled
        }
        return _unpinned
    }
    #endif
}
