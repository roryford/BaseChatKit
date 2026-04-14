import Foundation
import Security

/// Errors thrown by `KeychainService` when the underlying SecItem call fails.
///
/// `retrieve(account:)` intentionally does **not** throw — a missing item is a
/// normal state (represented by `nil`), not an error.
public enum KeychainError: Error, Equatable {
    /// `SecItemAdd` / `SecItemUpdate` returned a non-success `OSStatus`.
    case storeFailed(OSStatus)
    /// `SecItemDelete` returned a non-success `OSStatus` (other than `errSecItemNotFound`,
    /// which is treated as success).
    case deleteFailed(OSStatus)
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
