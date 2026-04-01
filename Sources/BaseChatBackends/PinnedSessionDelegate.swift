import Foundation
import CommonCrypto
import BaseChatCore

/// URLSession delegate that performs certificate pinning for known API hosts.
///
/// Validates the server's leaf certificate SPKI (Subject Public Key Info) SHA-256
/// hash against a set of known pins for Anthropic and OpenAI APIs. Connections to
/// unknown hosts (custom endpoints) fall through to default trust evaluation.
/// Localhost hosts always bypass pinning.
///
/// Pin rotation: when a provider rotates certificates, update the pin sets below.
/// Include at least one backup pin per host to avoid lockout during rotation.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {

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
    /// These pins are intentionally left empty and must be populated with actual
    /// SPKI hashes before enabling pinning in production.
    ///
    /// `api.openai.com` and `api.anthropic.com` are treated as required pinned
    /// production hosts: missing or empty pin sets fail closed.
    /// Unknown custom hosts continue to use default trust when no pins are set.
    // NSLock guards concurrent reads/writes from multiple URLSession delegate
    // callback threads, which can arrive on arbitrary background threads.
    private static let _pinnedHostsLock = NSLock()
    private static var _pinnedHosts: [String: Set<String>] = [:]

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
    // Populate with actual SPKI SHA-256 base64 hashes before enabling:
    // pinnedHosts["api.anthropic.com"] = Set(["hash1...", "hash2-backup..."])
    // pinnedHosts["api.openai.com"] = Set(["hash1...", "hash2-backup..."])

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

        // Extract the leaf certificate's public key and compute its SPKI SHA-256 hash.
        guard let leafCert = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = leafCert.first,
              let publicKey = SecCertificateCopyKey(certificate) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let hash = sha256(data: publicKeyData)
        let base64Hash = hash.base64EncodedString()

        if expectedPins.contains(base64Hash) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            Log.network.error("Certificate pin mismatch for \(host). Expected one of \(expectedPins.count) pins, got: \(base64Hash)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
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
