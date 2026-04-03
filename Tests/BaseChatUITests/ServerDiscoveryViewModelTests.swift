import XCTest
import SwiftData
import Observation
@testable import BaseChatUI
import BaseChatCore
import BaseChatTestSupport

@MainActor
final class ServerDiscoveryViewModelTests: XCTestCase {

    private var sut: ServerDiscoveryViewModel!
    private var mockService: MockServerDiscoveryService!

    override func setUp() async throws {
        mockService = MockServerDiscoveryService()
        sut = ServerDiscoveryViewModel(discoveryService: mockService)
    }

    override func tearDown() async throws {
        sut.stopDiscovery()
        sut = nil
        mockService = nil
    }

    // MARK: - Initial State

    func test_initialState() {
        XCTAssertTrue(sut.discoveredServers.isEmpty)
        XCTAssertFalse(sut.isScanning)
        XCTAssertNil(sut.selectedServer)
        XCTAssertNil(sut.errorMessage)
        XCTAssertTrue(sut.manualHost.isEmpty)
        XCTAssertTrue(sut.manualPort.isEmpty)
    }

    // MARK: - Discovery Lifecycle

    func test_startDiscovery_callsService() {
        mockService.serversToEmit = [makeOllamaServer()]
        sut.startDiscovery()

        XCTAssertTrue(sut.isScanning)
    }

    func test_stopDiscovery_callsServiceAndClearsScanning() {
        sut.startDiscovery()
        sut.stopDiscovery()

        XCTAssertEqual(mockService.stopCallCount, 1)
        XCTAssertFalse(sut.isScanning)
    }

    func test_discoveredServers_updatedFromService() async throws {
        let server = makeOllamaServer()
        mockService.serversToEmit = [server]

        sut.startDiscovery()

        // Wait for the async stream to deliver using Observation tracking
        let expectation = XCTestExpectation(description: "Server discovered")
        if !sut.discoveredServers.isEmpty {
            expectation.fulfill()
        } else {
            withObservationTracking {
                _ = sut.discoveredServers
            } onChange: {
                Task { @MainActor in expectation.fulfill() }
            }
        }
        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(sut.discoveredServers.count, 1)
        XCTAssertEqual(sut.discoveredServers.first?.displayName, "Ollama")
    }

    // MARK: - Manual Probe

    func test_probeManualEntry_emptyHost_setsError() async {
        sut.manualHost = ""
        await sut.probeManualEntry()

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertEqual(mockService.probeCallCount, 0)
    }

    func test_probeManualEntry_validHost_probesService() async {
        sut.manualHost = "192.168.1.100"
        sut.manualPort = "11434"
        mockService.probeResult = makeOllamaServer(host: "192.168.1.100")

        await sut.probeManualEntry()

        XCTAssertEqual(mockService.probeCallCount, 1)
        XCTAssertEqual(sut.discoveredServers.count, 1)
        XCTAssertNotNil(sut.selectedServer)
        XCTAssertNil(sut.errorMessage)
    }

    func test_probeManualEntry_noServerFound_setsError() async {
        sut.manualHost = "192.168.1.100"
        mockService.probeResult = nil

        await sut.probeManualEntry()

        XCTAssertNotNil(sut.errorMessage)
        XCTAssertTrue(sut.errorMessage!.contains("No server found"))
    }

    func test_probeManualEntry_defaultPort() async {
        sut.manualHost = "myserver.local"
        sut.manualPort = "" // should default to 11434
        mockService.probeResult = makeOllamaServer(host: "myserver.local")

        await sut.probeManualEntry()

        XCTAssertEqual(mockService.probeCallCount, 1)
    }

    func test_probeManualEntry_duplicateServerNotAdded() async {
        let server = makeOllamaServer()
        sut.manualHost = server.host
        sut.manualPort = "\(server.port)"
        mockService.probeResult = server

        await sut.probeManualEntry()
        await sut.probeManualEntry()

        XCTAssertEqual(sut.discoveredServers.count, 1, "Should not add duplicate")
    }

    // MARK: - Endpoint Creation

    func test_createEndpoint_createsValidEndpoint() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let server = makeOllamaServer()
        let model = RemoteModelInfo(name: "llama3.2", sizeBytes: 2_000_000_000)

        let endpoint = sut.createEndpoint(server: server, model: model, modelContext: context)

        XCTAssertEqual(endpoint.provider, APIProvider.ollama)
        XCTAssertEqual(endpoint.modelName, "llama3.2")
        XCTAssertTrue(endpoint.name.contains("Ollama"))
        XCTAssertTrue(endpoint.name.contains("llama3.2"))
    }

    func test_createEndpoint_koboldCppProvider() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let server = DiscoveredServer(
            displayName: "KoboldCpp",
            host: "localhost",
            port: 5001,
            serverType: .koboldCpp,
            models: [RemoteModelInfo(name: "mistral-7b")]
        )

        let endpoint = sut.createEndpoint(
            server: server,
            model: server.models[0],
            modelContext: context
        )

        XCTAssertEqual(endpoint.provider, APIProvider.koboldCpp)
        XCTAssertEqual(endpoint.baseURL, "http://localhost:5001")
    }

    // MARK: - Helpers

    private func makeOllamaServer(host: String = "localhost") -> DiscoveredServer {
        DiscoveredServer(
            displayName: "Ollama",
            host: host,
            port: 11434,
            serverType: .ollama,
            models: [
                RemoteModelInfo(name: "llama3.2", sizeBytes: 2_000_000_000),
                RemoteModelInfo(name: "mistral", sizeBytes: 4_000_000_000),
            ]
        )
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(BaseChatSchema.allModelTypes)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
