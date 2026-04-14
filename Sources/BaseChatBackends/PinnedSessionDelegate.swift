import Foundation
import CommonCrypto
import BaseChatInference

/// URLSession delegate that performs certificate pinning for known API hosts.
///
/// Validates the server's leaf certificate SPKI (Subject Public Key Info) SHA-256
/// hash against a set of known pins for Anthropic and OpenAI APIs. Connections to
/// unknown hosts (custom endpoints) fall through to default trust evaluation.
/// Localhost hosts always bypass pinning.
///
/// Pin rotation: when a provider rotates certificates, update the pin sets below.
/// Include at least one backup pin per host to avoid lockout during rotation.
final class PinnedSessionDelegate: NSObject, @preconcurrency URLSessionDelegate {

    // MARK: - Pin Sets

    /// SPKI SHA-256 hashes for known API hosts.
    ///
    /// To generate a pin from a certificate:
    /// ```bash
    /// openssl s_client -connect api.anthropic.com:443 </dev/null 2>/dev/null | \
    ///   openssl x509 -pubkey -noout | \
    ///   openssl pkey -pubin -outform DER | \
    ///   openssl dgst -sha256 -binary | base64
    /// ```
    ///
    /// Default pins are populated lazily by `loadDefaultPins()` on first access.
    /// Today that function ships two SPKI hashes — the Google Trust Services WE1
    /// intermediate CA and its issuing GTS Root R4 — and applies them to both
    /// `api.openai.com` and `api.anthropic.com` because both providers sit
    /// behind Google Trust Services. Pinning the intermediate (plus the root as
    /// a backup) rather than the leaf keeps the pin set stable across routine
    /// leaf-certificate renewals: pins only need to change when a provider
    /// rotates its signing infrastructure.
    ///
    /// `api.openai.com` and `api.anthropic.com` are treated as required pinned
    /// production hosts: missing or empty pin sets fail closed.
    /// Unknown custom hosts continue to use default trust when no pins are set.
    ///
    /// Host apps that need to override or extend the shipped pin set (e.g.
    /// pointing a provider at a private gateway with its own CA) can write
    /// directly to `pinnedHosts` before any network requests are issued; values
    /// set by the host app are preserved by `loadDefaultPins()`.
    // NSLock guards concurrent reads/writes from multiple URLSession delegate
    // callback threads, which can arrive on arbitrary background threads.
    private static let _pinnedHostsLock = NSLock()
    private nonisolated(unsafe) static var _pinnedHosts: [String: Set<String>] = [:]

    public static var pinnedHosts: [String: Set<String>] {
        get {
            _pinnedHostsLock.lock()
            defer { _pinnedHostsLock.unlock() }
            return _pinnedHosts
        }
        set {
            _pinnedHostsLock.lock()
            defer { _pinnedHostsLock.unlock() }
            _pinnedHosts = newValue
        }
    }
    /// Populates pin sets for known production hosts on first access.
    ///
    /// Pins target the intermediate CA (Google Trust Services WE1) and its
    /// issuing root (GTS Root R4). Intermediate pins are more stable than leaf
    /// pins — they survive individual certificate renewals and only change when
    /// the provider rotates its signing infrastructure.
    ///
    /// **Rotation procedure:**
    /// 1. Run the `openssl` pipeline from the doc comment above for each host.
    /// 2. Add the *new* intermediate/root pins to the set **before** removing old ones.
    /// 3. Ship the update. Once no connections use the old chain, remove stale pins.
    private nonisolated(unsafe) static var _defaultPinsLoaded = false

    static func loadDefaultPins() {
        _pinnedHostsLock.lock()
        defer { _pinnedHostsLock.unlock() }
        guard !_defaultPinsLoaded else { return }
        _defaultPinsLoaded = true

        // Google Trust Services WE1 (intermediate — shared by both hosts)
        let gtsWE1 = "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4="
        // GTS Root R4 (root CA — backup pin for rotation safety)
        let gtsRootR4 = "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c="
        let defaults = Set([gtsWE1, gtsRootR4])

        // Only set defaults if the host app hasn't already configured pins.
        // Access _pinnedHosts directly — we already hold the lock.
        for host in ["api.anthropic.com", "api.openai.com"] {
            if _pinnedHosts[host] == nil {
                _pinnedHosts[host] = defaults
            }
        }
    }

    /// Resets the one-shot guard so `loadDefaultPins()` can be called again.
    /// Intended for tests only (`@testable import`).
    static func resetDefaultPinsForTesting() {
        _pinnedHostsLock.lock()
        defer { _pinnedHostsLock.unlock() }
        _defaultPinsLoaded = false
    }

    /// Hosts that bypass pinning entirely (local development servers).
    private static let bypassHosts: Set<String> = [
        "localhost", "127.0.0.1", "::1"
    ]
    
    /// Known production hosts that must have non-empty pin sets configured.
    private static let requiredPinnedHosts: Set<String> = [
        "api.openai.com",
        "api.anthropic.com"
    ]

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Bypass pinning for localhost / local network servers.
        if Self.bypassHosts.contains(host) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let pins = Self.pinnedHosts[host]
        if Self.requiredPinnedHosts.contains(host) {
            guard let requiredPins = pins, !requiredPins.isEmpty else {
                Log.network.error("PinnedSessionDelegate: no certificate pins configured for required production host \(host, privacy: .public). Cancelling authentication challenge (fail-closed).")
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }

        // If no pins are configured for a custom host, fall back to default trust.
        guard let expectedPins = pins, !expectedPins.isEmpty else {
            Log.network.warning("PinnedSessionDelegate: no pins configured for custom host \(host, privacy: .public). Falling back to default trust evaluation.")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            Log.network.error("PinnedSessionDelegate: missing server trust for pinned host \(host, privacy: .public). Cancelling authentication challenge.")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Evaluate the trust chain first.
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            Log.network.error("Certificate trust evaluation failed for \(host): \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check every certificate in the chain (leaf, intermediates, root) against
        // the pin set. This lets us pin intermediates or roots — more stable than
        // leaf-only pinning because individual server certs rotate frequently.
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              !certChain.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        var seenHashes: [String] = []
        for certificate in certChain {
            guard let publicKey = SecCertificateCopyKey(certificate),
                  let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
                continue
            }
            let hash = sha256(data: publicKeyData)
            let base64Hash = hash.base64EncodedString()
            seenHashes.append(base64Hash)

            if expectedPins.contains(base64Hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        Log.network.error("Certificate pin mismatch for \(host). No certificate in chain matched any of \(expectedPins.count) pins. Seen hashes: \(seenHashes.joined(separator: ", "))")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Helpers

    private func sha256(data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }
}
