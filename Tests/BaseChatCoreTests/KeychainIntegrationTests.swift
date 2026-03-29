import XCTest
@testable import BaseChatCore

/// Integration tests for KeychainService using the REAL system Keychain.
///
/// These tests exercise actual SecItem operations against the macOS/iOS Keychain.
/// Each test uses a unique service name to avoid cross-test and cross-run conflicts.
/// May need to be skipped on CI environments without Keychain access.
final class KeychainIntegrationTests: XCTestCase {

    /// Unique service name scoped to this test run to avoid conflicts.
    private var testServiceName: String!

    /// Accounts created during the test, cleaned up in tearDown.
    private var createdAccounts: [String] = []

    /// Original configuration, restored in tearDown.
    private var originalConfig: BaseChatConfiguration!

    override func setUp() {
        super.setUp()
        originalConfig = BaseChatConfiguration.shared

        // Use a unique service name per test run to avoid Keychain collisions.
        testServiceName = "com.basechatkit.tests.keychain.\(UUID().uuidString)"

        // Configure BaseChatKit to use our test service name.
        var config = BaseChatConfiguration.shared
        config.bundleIdentifier = testServiceName
        BaseChatConfiguration.shared = config
    }

    override func tearDown() {
        // Clean up all Keychain entries created during the test.
        for account in createdAccounts {
            KeychainService.delete(account: account)
        }
        createdAccounts.removeAll()

        // Restore original configuration.
        BaseChatConfiguration.shared = originalConfig
        originalConfig = nil
        testServiceName = nil
        super.tearDown()
    }

    private func uniqueAccount() -> String {
        let account = "test_\(UUID().uuidString)"
        createdAccounts.append(account)
        return account
    }

    // MARK: - Write → Read → Verify Round-Trip

    func test_writeReadVerify_roundTrip() {
        let account = uniqueAccount()
        let apiKey = "sk-test-abc123def456ghi789"

        let stored = KeychainService.store(key: apiKey, account: account)
        XCTAssertTrue(stored, "Storing an API key should succeed")

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, apiKey, "Retrieved key should match stored key exactly")
    }

    // MARK: - Write → Delete → Read Returns Nil

    func test_writeDeleteRead_returnsNil() {
        let account = uniqueAccount()

        KeychainService.store(key: "temporary-key", account: account)
        let deleted = KeychainService.delete(account: account)
        XCTAssertTrue(deleted, "Delete should succeed")

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Key should be nil after deletion")
    }

    // MARK: - Overwrite Existing Key

    func test_overwriteExistingKey() {
        let account = uniqueAccount()

        KeychainService.store(key: "original-value", account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), "original-value")

        KeychainService.store(key: "updated-value", account: account)
        XCTAssertEqual(
            KeychainService.retrieve(account: account), "updated-value",
            "Second store should overwrite the first value"
        )
    }

    // MARK: - Read Non-Existent Key Returns Nil

    func test_readNonExistentKey_returnsNil() {
        let account = uniqueAccount()
        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Retrieving a never-stored key should return nil")
    }

    // MARK: - Store and Retrieve API Key-Like Strings

    func test_storeAndRetrieve_openAIStyleKey() {
        let account = uniqueAccount()
        let key = "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJ"

        KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_anthropicStyleKey() {
        let account = uniqueAccount()
        let key = "sk-ant-api03-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-AAAAAA"

        KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_keyWithSpecialCharacters() {
        let account = uniqueAccount()
        let key = "key/with+special=chars&more%20stuff"

        KeychainService.store(key: key, account: account)
        XCTAssertEqual(KeychainService.retrieve(account: account), key)
    }

    func test_storeAndRetrieve_emptyString() {
        let account = uniqueAccount()
        let key = ""

        KeychainService.store(key: key, account: account)
        XCTAssertEqual(
            KeychainService.retrieve(account: account), key,
            "Empty string should round-trip through Keychain"
        )
    }

    // MARK: - Multiple Accounts Are Isolated

    func test_multipleAccounts_doNotInterfere() {
        let account1 = uniqueAccount()
        let account2 = uniqueAccount()
        let account3 = uniqueAccount()

        KeychainService.store(key: "key-one", account: account1)
        KeychainService.store(key: "key-two", account: account2)
        KeychainService.store(key: "key-three", account: account3)

        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertEqual(KeychainService.retrieve(account: account2), "key-two")
        XCTAssertEqual(KeychainService.retrieve(account: account3), "key-three")

        // Deleting one should not affect others.
        KeychainService.delete(account: account2)
        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertNil(KeychainService.retrieve(account: account2))
        XCTAssertEqual(KeychainService.retrieve(account: account3), "key-three")
    }
}
