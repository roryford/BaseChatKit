import Foundation
import Security

/// Errors thrown by `KeychainService` when the underlying SecItem call fails.
///
/// `retrieve(account:)` intentionally does **not** throw — a missing item is a
/// normal state (represented by `nil`), not an error.
///
/// Conforms to `LocalizedError` so `error.localizedDescription` returns a
/// human-readable string suitable for presenting in a settings banner. Apps
/// that need to branch on the raw `OSStatus` (e.g. to distinguish "device
/// locked" from "entitlement missing") can read ``osStatus``.
public enum KeychainError: Error, Equatable, LocalizedError {
    /// `SecItemAdd` / `SecItemUpdate` returned a non-success `OSStatus`.
    case storeFailed(OSStatus)
    /// `SecItemDelete` returned a non-success `OSStatus` (other than `errSecItemNotFound`,
    /// which is treated as success).
    case deleteFailed(OSStatus)

    /// The underlying Keychain `OSStatus` that triggered the failure. Exposed
    /// so callers can branch on specific codes without pattern-matching the
    /// enum (e.g. `errSecInteractionNotAllowed` → "device is locked").
    public var osStatus: OSStatus {
        switch self {
        case .storeFailed(let status), .deleteFailed(let status):
            return status
        }
    }

    public var errorDescription: String? {
        let action: String
        switch self {
        case .storeFailed: action = "store"
        case .deleteFailed: action = "delete"
        }
        return "Couldn't \(action) the API key in the Keychain: \(Self.message(for: osStatus)) (OSStatus \(osStatus))."
    }

    /// Maps common Keychain `OSStatus` codes to short, user-facing strings.
    /// Unknown codes fall back to the generic `SecCopyErrorMessageString` if
    /// available, else a placeholder — the raw code is always appended by
    /// ``errorDescription`` so diagnostics are not lost.
    private static func message(for status: OSStatus) -> String {
        switch status {
        case errSecInteractionNotAllowed:
            return "The device appears to be locked. Unlock and try again"
        case errSecAuthFailed:
            return "Keychain authentication failed"
        case errSecMissingEntitlement:
            return "The app is missing the Keychain entitlement"
        case errSecNotAvailable:
            return "The Keychain is not available"
        case errSecDuplicateItem:
            return "A conflicting Keychain item already exists"
        case errSecDecode:
            return "The stored Keychain item could not be decoded"
        case errSecUserCanceled:
            return "The operation was cancelled"
        default:
            if let cf = SecCopyErrorMessageString(status, nil) {
                return cf as String
            }
            return "Keychain rejected the request"
        }
    }
}

/// Secure storage for API keys using the system Keychain.
///
/// Keys are stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` —
/// they do not sync to iCloud and are not available when the device is locked.
public enum KeychainService {

    private static var serviceName: String {
        BaseChatConfiguration.shared.keychainServiceName
    }

    /// Stores or updates an API key for the given account identifier.
    ///
    /// Throws `KeychainError.storeFailed` if the Keychain rejects the write
    /// (locked device, entitlement mismatch, corrupted item, etc.). Callers
    /// should surface the failure to the user — silently dropping the error
    /// leaves the app in a state where the user thinks their key is saved
    /// but later sees mysterious auth failures.
    public static func store(key: String, account: String) throws {
        let data = Data(key.utf8)

        // Try to update first
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        // If not found, add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            Log.inference.error(
                "KeychainService.store failed: status=\(addStatus, privacy: .public) account=\(account, privacy: .private)"
            )
            throw KeychainError.storeFailed(addStatus)
        }
    }

    /// Retrieves an API key for the given account identifier.
    /// Returns `nil` if not found.
    public static func retrieve(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes an API key for the given account identifier.
    ///
    /// `errSecItemNotFound` is treated as success — deleting something that
    /// was never there is not an error. Any other non-success `OSStatus`
    /// throws `KeychainError.deleteFailed`.
    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.inference.error(
                "KeychainService.delete failed: status=\(status, privacy: .public) account=\(account, privacy: .private)"
            )
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Returns a masked version of an API key for safe logging.
    /// e.g., "sk-abc...xyz" -> "sk-a...xyz"
    public static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        let prefix = String(key.prefix(4))
        let suffix = String(key.suffix(3))
        return "\(prefix)...\(suffix)"
    }
}
