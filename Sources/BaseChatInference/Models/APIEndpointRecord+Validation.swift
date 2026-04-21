import Foundation

extension APIEndpointRecord {

    /// Validates the `baseURL` for structural correctness and SSRF safety.
    ///
    /// Mirrors the policy defined in `APIEndpoint.validate()` (BaseChatCore) so
    /// that the `BaseChatInference` module cannot be bypassed by constructing an
    /// `APIEndpointRecord` directly — e.g. through programmatic injection —
    /// without going through the SwiftData wrapper. Both implementations **must
    /// stay in sync** whenever validation rules change.
    ///
    /// For the specific per-reason error description surfaced in UI, use
    /// `APIEndpoint.validate()` and `APIEndpointValidationReason` (BaseChatCore).
    /// This method throws `CloudBackendError.invalidURL` for any rejection so
    /// callers that only need a pass/fail answer do not need to import BaseChatCore.
    func validate() throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              url.host() != nil else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        guard scheme == "http" || scheme == "https" else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        // Loopback dev servers (e.g. Ollama, LM Studio) are allowed over plain HTTP.
        if Self.isLocalhost(url) { return }

        // Non-loopback must use HTTPS.
        guard scheme == "https" else {
            throw CloudBackendError.invalidURL(baseURL)
        }

        // Block SSRF pivots into private/link-local/reserved ranges even over HTTPS.
        if Self.isDisallowedPrivateHost(url) {
            throw CloudBackendError.invalidURL(baseURL)
        }
    }

    // MARK: - Internal helpers (package-private for tests)

    static func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func isDisallowedPrivateHost(_ url: URL) -> Bool {
        guard let rawHost = url.host()?.lowercased() else { return false }
        // Trailing-dot FQDN form resolves identically to the dotless form.
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        if let octets = parseIPv4Literal(host) {
            return classifyIPv4(octets)
        }
        if let words = parseIPv6Literal(host) {
            return classifyIPv6(words)
        }
        return false
    }

    // MARK: - IPv4

    private static func parseIPv4Literal(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII),
                  let value = UInt16(part), value <= 255 else { return nil }
            octets.append(UInt8(value))
        }
        return octets
    }

    private static func classifyIPv4(_ octets: [UInt8]) -> Bool {
        let a = octets[0], b = octets[1]
        if a == 10 { return true }                            // 10.0.0.0/8 RFC1918
        if a == 172 && (16...31).contains(b) { return true } // 172.16.0.0/12 RFC1918
        if a == 192 && b == 168 { return true }              // 192.168.0.0/16 RFC1918
        if a == 169 && b == 254 { return true }              // 169.254.0.0/16 link-local / IMDS
        if a == 0 { return true }                            // 0.0.0.0/8 any-address
        if a == 127 { return true }                          // 127.x.x.x alternate loopback
        if a >= 224 { return true }                          // 224–255 multicast + reserved
        return false
    }

    // MARK: - IPv6

    private static func parseIPv6Literal(_ host: String) -> [UInt16]? {
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard bare.contains(":") else { return nil }

        let doubleColonParts = bare.components(separatedBy: "::")
        guard doubleColonParts.count <= 2 else { return nil }

        func expand(_ segment: String) -> [UInt16]? {
            if segment.isEmpty { return [] }
            let groups = segment.split(separator: ":", omittingEmptySubsequences: false)
            var words: [UInt16] = []
            for (i, group) in groups.enumerated() {
                if group.contains(".") {
                    guard i == groups.count - 1,
                          let v4 = parseIPv4Literal(String(group)) else { return nil }
                    words.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
                    words.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
                } else {
                    guard !group.isEmpty, group.count <= 4,
                          let value = UInt16(group, radix: 16) else { return nil }
                    words.append(value)
                }
            }
            return words
        }

        let head = expand(doubleColonParts[0])
        let tail = doubleColonParts.count == 2 ? expand(doubleColonParts[1]) : []
        guard let headWords = head, let tailWords = tail else { return nil }

        let total = headWords.count + tailWords.count
        if doubleColonParts.count == 2 {
            guard total <= 8 else { return nil }
            return headWords + Array(repeating: 0, count: 8 - total) + tailWords
        } else {
            guard total == 8 else { return nil }
            return headWords
        }
    }

    private static func classifyIPv6(_ words: [UInt16]) -> Bool {
        guard words.count == 8 else { return false }
        if (words[0] & 0xfe00) == 0xfc00 { return true }  // fc00::/7 unique local
        if (words[0] & 0xffc0) == 0xfe80 { return true }  // fe80::/10 link-local
        // ::ffff:0:0/96 IPv4-mapped — reject wholesale to prevent IPv4-filter bypass.
        let isIPv4Mapped = words[0] == 0 && words[1] == 0 && words[2] == 0
            && words[3] == 0 && words[4] == 0 && words[5] == 0xffff
        return isIPv4Mapped
    }
}
