import XCTest
@testable import BaseChatCore
import BaseChatTestSupport

final class NetworkDiscoveryServiceTests: XCTestCase {

    private var service: NetworkDiscoveryService!
    private var stubbedURLs: [URL] = []

    /// Each test uses a UUID hostname so stubs never collide across concurrent suites.
    private var testHost: String!

    override func setUp() {
        super.setUp()
        testHost = UUID().uuidString

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        service = NetworkDiscoveryService(session: session)
    }

    override func tearDown() {
        for url in stubbedURLs {
            MockURLProtocol.unstub(url: url)
        }
        stubbedURLs = []
        service = nil
        testHost = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func stubURL(_ urlString: String, json: String, statusCode: Int = 200) {
        let url = URL(string: urlString)!
        MockURLProtocol.stub(
            url: url,
            response: .immediate(
                data: Data(json.utf8),
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"]
            )
        )
        stubbedURLs.append(url)
    }

    private func stubURL(_ urlString: String, error: Error) {
        let url = URL(string: urlString)!
        MockURLProtocol.stub(url: url, response: .error(error))
        stubbedURLs.append(url)
    }

    // MARK: - Ollama Parsing

    func test_ollama_validResponse_parsesModelsWithQuantization() async {
        let json = """
        {
            "models": [
                {"name": "llama3.2:7b-q4_0", "size": 4200000000},
                {"name": "mistral:latest", "size": 7000000000}
            ]
        }
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.serverType, .ollama)
        XCTAssertEqual(server?.displayName, "Ollama")
        XCTAssertEqual(server?.models.count, 2)

        let llama = server?.models.first { $0.name == "llama3.2:7b-q4_0" }
        XCTAssertNotNil(llama)
        XCTAssertEqual(llama?.sizeBytes, 4_200_000_000)
        // Sabotage check: removing the split(separator: ":") logic would make quantization nil
        XCTAssertEqual(llama?.quantization, "7b-q4_0")

        let mistral = server?.models.first { $0.name == "mistral:latest" }
        XCTAssertNotNil(mistral)
        XCTAssertEqual(mistral?.quantization, "latest")
    }

    func test_ollama_modelWithoutColon_hasNilQuantization() async {
        let json = """
        {"models": [{"name": "phi3", "size": 2000000000}]}
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertEqual(server?.models.count, 1)
        // Sabotage check: always setting quantization would break this
        XCTAssertNil(server?.models.first?.quantization)
    }

    func test_ollama_emptyModelList_returnsServerWithNoModels() async {
        let json = """
        {"models": []}
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertNotNil(server, "Server should still be discovered even with no models")
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_ollama_nullModelsKey_returnsServerWithNoModels() async {
        let json = """
        {"models": null}
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        // models key is null — parseOllamaModels guard returns []
        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_ollama_missingModelsKey_returnsServerWithNoModels() async {
        let json = """
        {"version": "0.1.0"}
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_ollama_malformedJSON_returnsServerWithNoModels() async {
        stubURL("http://\(testHost!):11434/api/tags", json: "not json at all")

        let server = await service.probe(host: testHost, port: 11434)

        // Server responds with 200, so it's discovered, but parsing fails gracefully
        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_ollama_modelWithNilSize_parsesSuccessfully() async {
        let json = """
        {"models": [{"name": "tiny:q4"}]}
        """
        stubURL("http://\(testHost!):11434/api/tags", json: json)

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertEqual(server?.models.count, 1)
        XCTAssertNil(server?.models.first?.sizeBytes)
        XCTAssertEqual(server?.models.first?.quantization, "q4")
    }

    // MARK: - LM Studio Parsing (uses OpenAI-compatible format)

    func test_lmStudio_validResponse_parsesMultipleModels() async {
        let json = """
        {
            "data": [
                {"id": "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF"},
                {"id": "TheBloke/Mistral-7B-Instruct-v0.2-GGUF"}
            ]
        }
        """
        stubURL("http://\(testHost!):1234/v1/models", json: json)

        let server = await service.probe(host: testHost, port: 1234)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.serverType, .lmStudio)
        XCTAssertEqual(server?.displayName, "LM Studio")
        XCTAssertEqual(server?.models.count, 2)

        // OpenAI format uses id for both id and name
        let llama = server?.models.first { $0.id == "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF" }
        XCTAssertNotNil(llama)
        // Sabotage check: parseOpenAIModels sets name = id
        XCTAssertEqual(llama?.name, "lmstudio-community/Meta-Llama-3-8B-Instruct-GGUF")
    }

    func test_lmStudio_emptyDataArray_returnsServerWithNoModels() async {
        let json = """
        {"data": []}
        """
        stubURL("http://\(testHost!):1234/v1/models", json: json)

        let server = await service.probe(host: testHost, port: 1234)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_lmStudio_nullData_returnsServerWithNoModels() async {
        let json = """
        {"data": null}
        """
        stubURL("http://\(testHost!):1234/v1/models", json: json)

        let server = await service.probe(host: testHost, port: 1234)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_lmStudio_malformedJSON_returnsServerWithNoModels() async {
        stubURL("http://\(testHost!):1234/v1/models", json: "<<<invalid>>>")

        let server = await service.probe(host: testHost, port: 1234)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    // MARK: - OpenAI-Compatible (arbitrary port)

    func test_openAICompatible_validResponse_parsesModels() async {
        let json = """
        {
            "data": [
                {"id": "gpt-4o"},
                {"id": "gpt-3.5-turbo"}
            ]
        }
        """
        // Port 8080 doesn't match any known server, so it falls through to OpenAI-compatible
        stubURL("http://\(testHost!):8080/v1/models", json: json)

        let server = await service.probe(host: testHost, port: 8080)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.serverType, .openAICompatible)
        // Sabotage check: display name includes host:port for unknown servers
        XCTAssertEqual(server?.displayName, "Server (\(testHost!):8080)")
        XCTAssertEqual(server?.models.count, 2)
        XCTAssertEqual(server?.models.first?.id, "gpt-4o")
        XCTAssertEqual(server?.models.first?.name, "gpt-4o")
    }

    func test_openAICompatible_emptyData_returnsServerWithNoModels() async {
        stubURL("http://\(testHost!):9090/v1/models", json: "{\"data\": []}")

        let server = await service.probe(host: testHost, port: 9090)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.serverType, .openAICompatible)
        XCTAssertEqual(server?.models.count, 0)
    }

    func test_openAICompatible_malformedJSON_returnsServerWithNoModels() async {
        stubURL("http://\(testHost!):9090/v1/models", json: "not-json")

        let server = await service.probe(host: testHost, port: 9090)

        XCTAssertNotNil(server)
        XCTAssertEqual(server?.models.count, 0)
    }

    // MARK: - HTTP Error Responses

    func test_probe_returns_nil_on_http500() async {
        let url = URL(string: "http://\(testHost!):11434/api/tags")!
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data(), statusCode: 500)
        )
        stubbedURLs.append(url)

        let server = await service.probe(host: testHost, port: 11434)

        // Sabotage check: removing the status code check would return a non-nil server
        XCTAssertNil(server, "500 responses should not produce a discovered server")
    }

    func test_probe_returns_nil_on_http404() async {
        let url = URL(string: "http://\(testHost!):5001/api/v1/model")!
        MockURLProtocol.stub(
            url: url,
            response: .immediate(data: Data(), statusCode: 404)
        )
        stubbedURLs.append(url)

        let server = await service.probe(host: testHost, port: 5001)

        XCTAssertNil(server)
    }

    // MARK: - Network Errors

    func test_probe_returns_nil_on_connectionRefused() async {
        stubURL("http://\(testHost!):11434/api/tags", error: URLError(.cannotConnectToHost))

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertNil(server, "Connection refused should return nil, not crash")
    }

    func test_probe_returns_nil_on_timeout() async {
        stubURL("http://\(testHost!):1234/v1/models", error: URLError(.timedOut))

        let server = await service.probe(host: testHost, port: 1234)

        XCTAssertNil(server, "Timeout should return nil gracefully")
    }

    func test_openAICompatible_returns_nil_on_networkError() async {
        stubURL("http://\(testHost!):8080/v1/models", error: URLError(.networkConnectionLost))

        let server = await service.probe(host: testHost, port: 8080)

        XCTAssertNil(server)
    }

    // MARK: - Server Metadata

    func test_discoveredServer_hostAndPort_matchProbeInput() async {
        stubURL("http://\(testHost!):11434/api/tags", json: "{\"models\": []}")

        let server = await service.probe(host: testHost, port: 11434)

        XCTAssertEqual(server?.host, testHost)
        XCTAssertEqual(server?.port, 11434)
    }

    func test_probe_knownPort_usesCorrectServerType() async {
        // Ollama on 11434
        stubURL("http://\(testHost!):11434/api/tags", json: "{\"models\": []}")
        let ollama = await service.probe(host: testHost, port: 11434)
        XCTAssertEqual(ollama?.serverType, .ollama)

        // LM Studio on 1234
        stubURL("http://\(testHost!):1234/v1/models", json: "{\"data\": []}")
        let lmStudio = await service.probe(host: testHost, port: 1234)
        XCTAssertEqual(lmStudio?.serverType, .lmStudio)

        // Unknown port falls through to OpenAI-compatible
        stubURL("http://\(testHost!):7777/v1/models", json: "{\"data\": []}")
        let openAI = await service.probe(host: testHost, port: 7777)
        // Sabotage check: removing the fallback to probeOpenAICompatible would return nil
        XCTAssertEqual(openAI?.serverType, .openAICompatible)
    }
}
