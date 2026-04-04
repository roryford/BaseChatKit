import Testing
import Foundation
import SwiftData
@testable import BaseChatUI
import BaseChatBackends
import BaseChatCore
import BaseChatTestSupport

private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

private let sseDone = Data("data: [DONE]\n\n".utf8)

private func sseChunks(_ tokens: [String]) -> [Data] {
    var chunks = tokens.map { token in
        sseData("""
        {"choices":[{"delta":{"content":"\(token)"}}]}
        """)
    }
    chunks.append(sseDone)
    return chunks
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private final class ConfiguringOpenAICloudBackend: InferenceBackend,
                                                   ConversationHistoryReceiver,
                                                   CloudBackendURLModelConfigurable,
                                                   CloudBackendKeychainConfigurable,
                                                   @unchecked Sendable {
    private let backend: OpenAIBackend
    private let probeOnLoad: Bool

    init(urlSession: URLSession, probeOnLoad: Bool = false) {
        self.backend = OpenAIBackend(urlSession: urlSession)
        self.probeOnLoad = probeOnLoad
    }

    var isModelLoaded: Bool { backend.isModelLoaded }
    var isGenerating: Bool { backend.isGenerating }
    var capabilities: BackendCapabilities { backend.capabilities }

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        backend.setConversationHistory(messages)
    }

    func configure(baseURL: URL, modelName: String) {
        backend.configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    }

    func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        backend.configure(baseURL: baseURL, keychainAccount: keychainAccount, modelName: modelName)
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        try await backend.loadModel(from: url, contextSize: contextSize)

        guard probeOnLoad else { return }
        let stream = try backend.generate(
            prompt: "probe",
            systemPrompt: nil,
            config: GenerationConfig(maxOutputTokens: 1)
        )
        for try await _ in stream { break }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        try backend.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
    }

    func stopGeneration() { backend.stopGeneration() }
    func unloadModel() { backend.unloadModel() }
    func resetConversation() { backend.resetConversation() }
}

private final class ConfiguringClaudeCloudBackend: InferenceBackend,
                                                   ConversationHistoryReceiver,
                                                   CloudBackendKeychainConfigurable,
                                                   @unchecked Sendable {
    private let backend: ClaudeBackend

    init(urlSession: URLSession) {
        self.backend = ClaudeBackend(urlSession: urlSession)
    }

    var isModelLoaded: Bool { backend.isModelLoaded }
    var isGenerating: Bool { backend.isGenerating }
    var capabilities: BackendCapabilities { backend.capabilities }

    func setConversationHistory(_ messages: [(role: String, content: String)]) {
        backend.setConversationHistory(messages)
    }

    func configure(baseURL: URL, keychainAccount: String, modelName: String) {
        backend.configure(baseURL: baseURL, keychainAccount: keychainAccount, modelName: modelName)
    }

    func loadModel(from url: URL, contextSize: Int32) async throws {
        try await backend.loadModel(from: url, contextSize: contextSize)
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> AsyncThrowingStream<String, Error> {
        try backend.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
    }

    func stopGeneration() { backend.stopGeneration() }
    func unloadModel() { backend.unloadModel() }
    func resetConversation() { backend.resetConversation() }
}

@Suite("Cloud Endpoint Selection E2E", .serialized)
@MainActor
final class CloudEndpointSelectionE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let localBackend: MockInferenceBackend
    private let vm: ChatViewModel
    private let sessionManager: SessionManagerViewModel
    private let cloudSession: URLSession

    init() throws {
        container = try makeInMemoryContainer()
        context = container.mainContext

        localBackend = MockInferenceBackend()
        cloudSession = makeMockSession()

        let service = InferenceService()
        let localRef = localBackend
        let cloudSessionRef = cloudSession
        service.registerBackendFactory { _ in localRef }
        service.registerCloudBackendFactory { _ in
            ConfiguringOpenAICloudBackend(urlSession: cloudSessionRef)
        }

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence)
    }

    private func makeLocalModel(name: String = "Local GGUF") -> ModelInfo {
        ModelInfo(
            name: name,
            fileName: "\(name).gguf",
            url: URL(fileURLWithPath: "/dev/null"),
            fileSize: 400_000_000,
            modelType: .gguf
        )
    }

    @discardableResult
    private func makeSession(title: String = "Test") throws -> ChatSessionRecord {
        let session = try sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        vm.switchToSession(session)
        return session
    }

    private func persistEndpoint(_ endpoint: APIEndpoint) throws {
        context.insert(endpoint)
        try context.save()
    }

    private func makeViewModel(cloudFactory: @escaping CloudBackendFactory) -> ChatViewModel {
        let service = InferenceService()
        service.registerCloudBackendFactory(cloudFactory)
        let viewModel = ChatViewModel(inferenceService: service)
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        viewModel.configure(persistence: persistence)
        return viewModel
    }

    @Test("selectedEndpoint + loadCloudEndpoint(endpoint) marks cloud backend as loaded")
    func selectedEndpointAndLoad_setsIsModelLoaded() async throws {
        let endpoint = APIEndpoint(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        try persistEndpoint(endpoint)

        vm.selectedEndpoint = endpoint
        await vm.loadCloudEndpoint(endpoint)

        #expect(vm.selectedEndpoint?.id == endpoint.id)
        #expect(vm.isModelLoaded)
        #expect(vm.errorMessage == nil)
    }

    @Test("sendMessage() streams cloud response via MockURLProtocol")
    func sendMessage_streamsCloudResponseViaMockURLProtocol() async throws {
        // UUID hostname isolates this stub from concurrently-running suites — no reset() needed.
        let uniqueHost = UUID().uuidString + ".invalid"

        try makeSession(title: "Cloud Chat")
        let endpoint = APIEndpoint(
            name: "Local LM Studio",
            provider: .lmStudio,
            baseURL: "http://\(uniqueHost)",
            modelName: "local-model"
        )
        try persistEndpoint(endpoint)

        let baseURL = try #require(URL(string: endpoint.baseURL))
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(
            url: completionsURL,
            response: .sse(chunks: sseChunks(["Hello", " cloud"]), statusCode: 200)
        )

        vm.selectedEndpoint = endpoint
        await vm.loadCloudEndpoint(endpoint)
        #expect(vm.isModelLoaded)

        vm.inputText = "Hi"
        await vm.sendMessage()

        #expect(vm.messages.count == 2)
        let user = try #require(vm.messages.first)
        let assistant = try #require(vm.messages.last)
        #expect(user.role == .user)
        #expect(assistant.role == .assistant)
        #expect(assistant.content == "Hello cloud")
        #expect(
            MockURLProtocol.capturedRequests.contains {
                $0.url?.absoluteString.hasPrefix(completionsURL.absoluteString) == true
            }
        )
    }

    @Test("Switching local model ↔ cloud endpoint keeps selections mutually exclusive")
    func modelAndEndpointSelection_areMutuallyExclusive() {
        let localModel = makeLocalModel()
        let endpoint = APIEndpoint(
            name: "Cloud Endpoint",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )

        vm.selectedModel = localModel
        vm.selectedEndpoint = endpoint
        #expect(vm.selectedModel == nil)
        #expect(vm.selectedEndpoint?.id == endpoint.id)

        vm.selectedModel = localModel
        #expect(vm.selectedEndpoint == nil)
        #expect(vm.selectedModel?.id == localModel.id)
    }

    @Test("Cloud endpoint is persisted to session and restored on switch-back")
    func sessionRestoresSelectedEndpoint() throws {
        let endpointA = APIEndpoint(
            name: "Endpoint A",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        let endpointB = APIEndpoint(
            name: "Endpoint B",
            provider: .lmStudio,
            baseURL: "http://localhost:1234",
            modelName: "local-model"
        )
        try persistEndpoint(endpointA)
        try persistEndpoint(endpointB)
        vm.setAvailableEndpoints([endpointA, endpointB])

        try makeSession(title: "Session A")
        vm.selectedEndpoint = endpointA
        try vm.saveSettingsToSession()

        let sessionB = try sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        vm.switchToSession(sessionB)
        vm.selectedEndpoint = endpointB
        try vm.saveSettingsToSession()

        sessionManager.loadSessions()
        let freshA = try #require(sessionManager.sessions.first { $0.title == "Session A" })
        sessionManager.activeSession = freshA
        vm.switchToSession(freshA)

        #expect(vm.selectedEndpoint?.id == endpointA.id)
    }

    @Test("loadCloudEndpoint failure path surfaces invalid URL, missing API key, and network error")
    func loadCloudEndpoint_failurePath_surfacesErrors() async throws {
        // Invalid URL
        let invalidEndpoint = APIEndpoint(
            name: "Bad URL",
            provider: .custom,
            baseURL: "http://foo\0bar",
            modelName: "model"
        )
        await vm.loadCloudEndpoint(invalidEndpoint)
        let invalidError = try #require(vm.errorMessage)
        #expect(invalidError.contains("Invalid server URL"))
        #expect(!vm.isModelLoaded)

        // Missing API key
        let missingKeyVM = makeViewModel { _ in
            ConfiguringClaudeCloudBackend(urlSession: makeMockSession())
        }
        let claudeEndpoint = APIEndpoint(
            name: "Claude Endpoint",
            provider: .claude,
            baseURL: "https://api.anthropic.com",
            modelName: "claude-sonnet-4-20250514"
        )
        KeychainService.delete(account: claudeEndpoint.keychainAccount)
        await missingKeyVM.loadCloudEndpoint(claudeEndpoint)
        let missingKeyError = try #require(missingKeyVM.errorMessage)
        #expect(missingKeyError.contains("No API key configured"))
        #expect(!missingKeyVM.isModelLoaded)

        // Network error from MockURLProtocol during load probe
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let probingSession = makeMockSession()
        let networkVM = makeViewModel { _ in
            ConfiguringOpenAICloudBackend(
                urlSession: probingSession,
                probeOnLoad: true
            )
        }
        let networkEndpoint = APIEndpoint(
            name: "Flaky Endpoint",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2"
        )
        let networkBaseURL = try #require(URL(string: networkEndpoint.baseURL))
        let networkCompletionsURL = networkBaseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(
            url: networkCompletionsURL,
            response: .error(URLError(.networkConnectionLost))
        )

        await networkVM.loadCloudEndpoint(networkEndpoint)
        let networkError = try #require(networkVM.errorMessage)
        #expect(!networkError.isEmpty)
        #expect(
            networkError.localizedCaseInsensitiveContains("nsurlerrordomain")
            || networkError.localizedCaseInsensitiveContains("connect")
            || networkError.localizedCaseInsensitiveContains("network")
        )
        #expect(!networkVM.isModelLoaded)
    }
}
