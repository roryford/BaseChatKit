import Testing
import Foundation
import SwiftData
@testable import BaseChatUI
@testable import BaseChatBackends
import BaseChatCore
import BaseChatTestSupport

/// Formats a single SSE data line from a JSON string.
private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

private let sseDone = Data("data: [DONE]\n\n".utf8)

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// E2E: discover server → create endpoint → configure backend → stream tokens.
///
/// Chains `MockServerDiscoveryService` → `ServerDiscoveryViewModel` →
/// `APIEndpoint` (persisted in SwiftData) → `OpenAIBackend` with
/// `MockURLProtocol` SSE stubs.
@Suite("Server Discovery → Generate Pipeline E2E", .serialized)
@MainActor
struct ServerDiscoveryGenerateE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let mockDiscovery: MockServerDiscoveryService
    private let discoveryVM: ServerDiscoveryViewModel

    init() throws {
        container = try makeInMemoryContainer()
        context = container.mainContext

        mockDiscovery = MockServerDiscoveryService()
        discoveryVM = ServerDiscoveryViewModel(discoveryService: mockDiscovery)
    }

    // MARK: - Helpers

    /// Creates an OpenAI-compatible backend configured from a persisted endpoint,
    /// with MockURLProtocol intercepting requests.
    private func makeBackend(endpoint: APIEndpoint) throws -> (OpenAIBackend, URL) {
        guard let baseURL = URL(string: endpoint.baseURL) else {
            Issue.record("endpoint.baseURL is not a valid URL: \(endpoint.baseURL)")
            throw URLError(.badURL)
        }
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        backend.configure(baseURL: baseURL, apiKey: nil, modelName: endpoint.modelName)
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        return (backend, completionsURL)
    }

    private func sseChunks(_ tokens: [String]) -> [Data] {
        var chunks = tokens.map { token in
            sseData("""
            {"choices":[{"delta":{"content":"\(token)"}}]}
            """)
        }
        chunks.append(sseData("""
        {"choices":[{"delta":{}}],"usage":{"prompt_tokens":10,"completion_tokens":\(tokens.count),"total_tokens":\(10 + tokens.count)}}
        """))
        chunks.append(sseDone)
        return chunks
    }

    /// Polls until `discoveredServers.count` reaches `expected`, with a 1-second timeout.
    private func waitForServers(count expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while discoveryVM.discoveredServers.count < expected {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(expected) discovered servers (got \(discoveryVM.discoveredServers.count))")
                return
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Tests

    @Test("Happy path: discover → select → create endpoint → stream tokens")
    func discoverSelectConfigureStream() async throws {
        // UUID hostname isolates this stub from concurrently-running suites.
        let ollamaHost = UUID().uuidString + ".invalid"
        defer { discoveryVM.stopDiscovery() }

        let server = DiscoveredServer(
            displayName: "Test Ollama",
            host: ollamaHost,
            port: 11434,
            serverType: .ollama,
            models: [RemoteModelInfo(name: "llama3.2", sizeBytes: 2_000_000_000)]
        )
        mockDiscovery.serversToEmit = [server]

        // Discover
        discoveryVM.startDiscovery()
        try await waitForServers(count: 1)
        #expect(discoveryVM.discoveredServers.count == 1)

        // Create persisted endpoint
        let discovered = discoveryVM.discoveredServers[0]
        let endpoint = discoveryVM.createEndpoint(
            server: discovered,
            model: discovered.models[0],
            modelContext: context
        )
        #expect(endpoint.provider == .ollama)
        #expect(endpoint.modelName == "llama3.2")

        // Verify the endpoint was persisted to SwiftData
        let fetched = try context.fetch(FetchDescriptor<APIEndpoint>())
        #expect(fetched.count == 1)
        #expect(fetched[0].modelName == "llama3.2")

        // Configure backend from persisted endpoint and stub SSE
        let (backend, url) = try makeBackend(endpoint: endpoint)
        MockURLProtocol.stub(url: url, response: .sse(chunks: sseChunks(["Hello", " world"]), statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["Hello", " world"])
    }

    @Test("Manual probe → configure → stream tokens")
    func manualProbeAndStream() async throws {
        // UUID hostname isolates this stub from concurrently-running suites.
        let probeHost = UUID().uuidString + ".invalid"

        let server = DiscoveredServer(
            displayName: "Manual LM Studio",
            host: probeHost,
            port: 1234,
            serverType: .lmStudio,
            models: [RemoteModelInfo(name: "mistral-7b")]
        )
        mockDiscovery.probeResult = server

        discoveryVM.manualHost = probeHost
        discoveryVM.manualPort = "1234"
        await discoveryVM.probeManualEntry()

        #expect(discoveryVM.discoveredServers.count == 1)
        #expect(discoveryVM.selectedServer != nil)

        let discovered = discoveryVM.discoveredServers[0]
        let endpoint = discoveryVM.createEndpoint(
            server: discovered,
            model: discovered.models[0],
            modelContext: context
        )
        #expect(endpoint.provider == .lmStudio)

        let (backend, url) = try makeBackend(endpoint: endpoint)
        MockURLProtocol.stub(url: url, response: .sse(chunks: sseChunks(["Probed", " reply"]), statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        let stream = try backend.generate(prompt: "Test", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["Probed", " reply"])
    }

    @Test("Discovered server becomes unreachable → error propagates")
    func serverUnreachableAfterDiscovery() async throws {
        // UUID hostname isolates this stub from concurrently-running suites.
        let ollamaHost = UUID().uuidString + ".invalid"
        defer { discoveryVM.stopDiscovery() }

        let server = DiscoveredServer(
            displayName: "Flaky Ollama",
            host: ollamaHost,
            port: 11434,
            serverType: .ollama,
            models: [RemoteModelInfo(name: "llama3.2")]
        )
        mockDiscovery.serversToEmit = [server]
        discoveryVM.startDiscovery()
        try await waitForServers(count: 1)

        let discovered = discoveryVM.discoveredServers[0]
        let endpoint = discoveryVM.createEndpoint(
            server: discovered,
            model: discovered.models[0],
            modelContext: context
        )
        let (backend, url) = try makeBackend(endpoint: endpoint)

        // Stub a network error
        MockURLProtocol.stub(url: url, response: .error(URLError(.networkConnectionLost)))
        defer { MockURLProtocol.unstub(url: url) }

        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)

        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
            Issue.record("Expected an error for unreachable server")
        } catch {
            #expect(error is URLError || error is CloudBackendError)
        }
    }

    @Test("Multiple servers: select second, stream from it")
    func multipleServersSelectSecond() async throws {
        // UUID hostname isolates this stub from concurrently-running suites — no reset() needed.
        let lmStudioHost = UUID().uuidString + ".invalid"
        defer { discoveryVM.stopDiscovery() }

        let ollama = DiscoveredServer(
            displayName: "Ollama",
            host: "localhost",
            port: 11434,
            serverType: .ollama,
            models: [RemoteModelInfo(name: "llama3.2")]
        )
        let lmStudio = DiscoveredServer(
            displayName: "LM Studio",
            host: lmStudioHost,
            port: 1234,
            serverType: .lmStudio,
            models: [RemoteModelInfo(name: "phi-3")]
        )
        mockDiscovery.serversToEmit = [ollama, lmStudio]
        discoveryVM.startDiscovery()
        try await waitForServers(count: 2)

        #expect(discoveryVM.discoveredServers.count == 2)

        // Select the second server
        let selected = discoveryVM.discoveredServers[1]
        discoveryVM.selectedServer = selected

        let endpoint = discoveryVM.createEndpoint(
            server: selected,
            model: selected.models[0],
            modelContext: context
        )
        #expect(endpoint.provider == .lmStudio)
        #expect(endpoint.modelName == "phi-3")

        let (backend, url) = try makeBackend(endpoint: endpoint)
        MockURLProtocol.stub(url: url, response: .sse(chunks: sseChunks(["From", " LM", " Studio"]), statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        try await backend.loadModel(from: URL(string: "unused:")!, contextSize: 0)
        let stream = try backend.generate(prompt: "Test", systemPrompt: nil, config: GenerationConfig())

        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["From", " LM", " Studio"])
    }
}
