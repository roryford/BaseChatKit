import XCTest
@testable import BaseChatInference

/// Tests for KeychainService secure storage operations.
final class KeychainServiceTests: XCTestCase {

    /// Tracks accounts created during each test for cleanup.
    private var createdAccounts: [String] = []

    override func tearDown() {
        super.tearDown()
        for account in createdAccounts {
            KeychainService.delete(account: account)
        }
        createdAccounts.removeAll()
    }

    private func uniqueAccount() -> String {
        let account = "test_\(UUID().uuidString)"
        createdAccounts.append(account)
        return account
    }

    // MARK: - Store & Retrieve

    func test_store_andRetrieve() {
        let account = uniqueAccount()
        let stored = KeychainService.store(key: "sk-test-key-123", account: account)
        XCTAssertTrue(stored, "Storing a key should succeed")

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, "sk-test-key-123")
    }

    func test_store_updatesExisting() {
        let account = uniqueAccount()
        KeychainService.store(key: "old-key", account: account)
        KeychainService.store(key: "new-key", account: account)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertEqual(retrieved, "new-key",
                       "Second store should overwrite the first value")
    }

    func test_retrieve_notFound_returnsNil() {
        let account = uniqueAccount()
        let result = KeychainService.retrieve(account: account)
        XCTAssertNil(result, "Retrieving a non-existent key should return nil")
    }

    // MARK: - Delete

    func test_delete_removesKey() {
        let account = uniqueAccount()
        KeychainService.store(key: "to-delete", account: account)
        let deleted = KeychainService.delete(account: account)
        XCTAssertTrue(deleted)

        let retrieved = KeychainService.retrieve(account: account)
        XCTAssertNil(retrieved, "Key should be gone after deletion")
    }

    func test_delete_nonExistent_returnsTrue() {
        let account = uniqueAccount()
        let result = KeychainService.delete(account: account)
        XCTAssertTrue(result, "Deleting a non-existent key should not fail")
    }

    // MARK: - Masking

    func test_masked_shortKey() {
        let masked = KeychainService.masked("abc")
        XCTAssertEqual(masked, "****",
                       "Keys shorter than 8 chars should be fully masked")
    }

    func test_masked_normalKey() {
        let masked = KeychainService.masked("sk-abc123xyz789")
        XCTAssertEqual(masked, "sk-a...789",
                       "Normal keys should show first 4 and last 3 chars")
    }

    // MARK: - Isolation

    func test_multipleAccounts_isolated() {
        let account1 = uniqueAccount()
        let account2 = uniqueAccount()

        KeychainService.store(key: "key-one", account: account1)
        KeychainService.store(key: "key-two", account: account2)

        XCTAssertEqual(KeychainService.retrieve(account: account1), "key-one")
        XCTAssertEqual(KeychainService.retrieve(account: account2), "key-two")
    }
}
