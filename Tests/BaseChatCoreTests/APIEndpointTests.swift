import XCTest
@testable import BaseChatCore

/// Tests for APIProvider enum and APIEndpoint model.
final class APIEndpointTests: XCTestCase {

    /// Track keychain accounts for cleanup.
    private var endpointIDs: [String] = []

    override func tearDown() {
        super.tearDown()
        for id in endpointIDs {
            KeychainService.delete(account: id)
        }
        endpointIDs.removeAll()
    }

    private func makeEndpoint(
        provider: APIProvider,
        baseURL: String? = nil,
        modelName: String? = nil
    ) -> APIEndpoint {
        let endpoint = APIEndpoint(name: "Test", provider: provider, baseURL: baseURL, modelName: modelName)
        endpointIDs.append(endpoint.id.uuidString)
        return endpoint
    }

    // MARK: - APIProvider

    func test_init_setsDefaults() {
        let endpoint = makeEndpoint(provider: .openAI)
        XCTAssertEqual(endpoint.provider, .openAI)
        XCTAssertEqual(endpoint.baseURL, "https://api.openai.com")
        XCTAssertEqual(endpoint.modelName, "gpt-4o-mini")
        XCTAssertTrue(endpoint.isEnabled)
    }

    func test_provider_roundTrip() {
        let endpoint = makeEndpoint(provider: .claude)
        XCTAssertEqual(endpoint.provider, .claude)

        endpoint.provider = .ollama
        XCTAssertEqual(endpoint.provider, .ollama)
        XCTAssertEqual(endpoint.providerRawValue, "Ollama")
    }

    func test_provider_allCases_haveDefaultURL() {
        for provider in APIProvider.allCases {
            XCTAssertFalse(provider.defaultBaseURL.isEmpty,
                           "\(provider) should have a non-empty default URL")
        }
    }

    func test_provider_requiresAPIKey() {
        XCTAssertTrue(APIProvider.openAI.requiresAPIKey)
        XCTAssertTrue(APIProvider.claude.requiresAPIKey)
        XCTAssertTrue(APIProvider.custom.requiresAPIKey)
        XCTAssertFalse(APIProvider.ollama.requiresAPIKey)
        XCTAssertFalse(APIProvider.lmStudio.requiresAPIKey)
    }

    // MARK: - isValid

    func test_isValid_validHTTPS() {
        let endpoint = makeEndpoint(provider: .openAI, baseURL: "https://api.openai.com")
        endpoint.setAPIKey("sk-valid-key")
        XCTAssertTrue(endpoint.isValid)
    }

    func test_isValid_httpLocalhost_valid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://localhost:11434")
        // Ollama doesn't require API key
        XCTAssertTrue(endpoint.isValid,
                      "HTTP localhost should be valid (exempt from HTTPS requirement)")
    }

    func test_isValid_httpRemote_invalid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://example.com")
        XCTAssertFalse(endpoint.isValid,
                       "HTTP non-localhost should be invalid")
    }

    func test_isValid_missingAPIKey_invalid() {
        let endpoint = makeEndpoint(provider: .openAI, baseURL: "https://api.openai.com")
        // No API key set — provider requires one
        XCTAssertFalse(endpoint.isValid,
                       "OpenAI endpoint without API key should be invalid")
    }

    func test_isValid_ollamaNoKey_valid() {
        let endpoint = makeEndpoint(provider: .ollama, baseURL: "http://localhost:11434")
        XCTAssertTrue(endpoint.isValid,
                      "Ollama without API key should be valid")
    }
}
