import Testing
import Foundation
@testable import BaseChatBackends

@Suite("SecureBytes")
struct SecureBytesTests {

    @Test("returns nil for empty string")
    func emptyStringIsNil() {
        #expect(SecureBytes("") == nil)
    }

    @Test("round-trips a non-empty key")
    func roundTrip() throws {
        let key = "sk-test-abc123"
        let secure = try #require(SecureBytes(key))
        #expect(secure.stringValue == key)
    }

    @Test("round-trips a key containing multi-byte UTF-8 characters")
    func roundTripMultiByte() throws {
        let key = "sk-\u{1F511}key"
        let secure = try #require(SecureBytes(key))
        #expect(secure.stringValue == key)
    }
}

@Suite("SSECloudBackend ephemeralAPIKey")
struct EphemeralAPIKeyTests {

    private func makeBackend() -> SSECloudBackend {
        SSECloudBackend(defaultModelName: "test-model", urlSession: .shared)
    }

    @Test("stores and retrieves a key")
    func storeAndRetrieve() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = "sk-abc"
        #expect(backend.ephemeralAPIKey == "sk-abc")
    }

    @Test("setting an empty string treats key as absent")
    func emptyStringBecomesNil() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = ""
        #expect(backend.ephemeralAPIKey == nil)
    }

    @Test("key is nil after unloadModel")
    func clearedAfterUnload() async {
        let backend = makeBackend()
        let url = URL(string: "https://api.test")!
        backend.configure(baseURL: url, apiKey: "sk-abc", modelName: "test-model")
        #expect(backend.ephemeralAPIKey == "sk-abc")
        backend.unloadModel()
        #expect(backend.ephemeralAPIKey == nil)
    }

    @Test("resolveAPIKey returns ephemeral key when no keychain account set")
    func resolveReturnsEphemeral() {
        let backend = makeBackend()
        let url = URL(string: "https://api.test")!
        backend.configure(baseURL: url, apiKey: "sk-resolve-test", modelName: "test-model")
        #expect(backend.resolveAPIKey() == "sk-resolve-test")
    }

    @Test("replacing a key with nil releases the old value")
    func replaceWithNil() {
        let backend = makeBackend()
        backend.ephemeralAPIKey = "sk-old"
        backend.ephemeralAPIKey = nil
        #expect(backend.ephemeralAPIKey == nil)
    }
}
