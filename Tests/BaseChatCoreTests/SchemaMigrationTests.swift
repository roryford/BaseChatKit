import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatTestSupport

/// Tests for the SwiftData VersionedSchema and SchemaMigrationPlan infrastructure.
final class SchemaMigrationTests: XCTestCase {

    // MARK: - BaseChatSchemaV1

    func test_schemaV1_versionIdentifier() {
        XCTAssertEqual(BaseChatSchemaV1.versionIdentifier, Schema.Version(1, 0, 0))
    }

    func test_schemaV1_modelsContainsAllExpectedTypes() {
        let models = BaseChatSchemaV1.models
        XCTAssertEqual(models.count, 4)
        let ids = models.map { ObjectIdentifier($0) }
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.ChatMessage.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.ChatSession.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.SamplerPreset.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(BaseChatSchemaV1.APIEndpoint.self)))
    }

    func test_publicTypealiases_matchSchemaV1ModelTypes() {
        XCTAssertEqual(ObjectIdentifier(ChatMessage.self), ObjectIdentifier(BaseChatSchemaV1.ChatMessage.self))
        XCTAssertEqual(ObjectIdentifier(ChatSession.self), ObjectIdentifier(BaseChatSchemaV1.ChatSession.self))
        XCTAssertEqual(ObjectIdentifier(SamplerPreset.self), ObjectIdentifier(BaseChatSchemaV1.SamplerPreset.self))
        XCTAssertEqual(ObjectIdentifier(APIEndpoint.self), ObjectIdentifier(BaseChatSchemaV1.APIEndpoint.self))
    }

    // MARK: - BaseChatMigrationPlan

    func test_migrationPlan_schemasContainsV1() {
        let names = BaseChatMigrationPlan.schemas.map { String(describing: $0) }
        XCTAssertTrue(names.contains(where: { $0.contains("BaseChatSchemaV1") }))
    }

    func test_migrationPlan_stagesIsEmpty_forBaselineV1() {
        // V1 is the baseline — no prior version to migrate from.
        XCTAssertTrue(BaseChatMigrationPlan.stages.isEmpty)
    }

    // MARK: - ModelContainerFactory

    func test_containerFactory_opensWithMigrationPlan() throws {
        // Verifies the container is functional: insert and fetch a ChatMessage.
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "ping", sessionID: sessionID)
        context.insert(message)
        try context.save()
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.content, "ping")
    }

    func test_containerFactory_makeContainer_inMemoryConfig() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainerFactory.makeContainer(configurations: [config])
        XCTAssertNotNil(container)
    }

    func test_schemaOwnedModelAndPublicAlias_areInterchangeable() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let nestedMessage = BaseChatSchemaV1.ChatMessage(role: .user, content: "alias check", sessionID: UUID())
        context.insert(nestedMessage)
        try context.save()
        let nestedMessageID = nestedMessage.id

        let fetchedViaAlias = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == nestedMessageID }
        ))
        XCTAssertEqual(fetchedViaAlias.count, 1)
        XCTAssertEqual(fetchedViaAlias.first?.content, "alias check")
    }

    // MARK: - Codable round-trip (ChatMessage)

    func test_chatMessage_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "Hello, world!", sessionID: sessionID)
        message.promptTokens = 10
        message.completionTokens = 42

        context.insert(message)
        try context.save()

        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.content, "Hello, world!")
        XCTAssertEqual(fetched0.role, .user)
        XCTAssertEqual(fetched0.promptTokens, 10)
        XCTAssertEqual(fetched0.completionTokens, 42)
    }

    // MARK: - Codable round-trip (ChatSession)

    func test_chatSession_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let session = ChatSession(title: "Migration test")
        session.systemPrompt = "You are helpful."
        session.temperature = 0.8

        context.insert(session)
        try context.save()

        let sessionID = session.id
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.title, "Migration test")
        XCTAssertEqual(fetched0.systemPrompt, "You are helpful.")
        let temp = try XCTUnwrap(fetched0.temperature)
        XCTAssertEqual(Double(temp), 0.8, accuracy: 0.001)
    }

    // MARK: - Codable round-trip (SamplerPreset)

    func test_samplerPreset_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let preset = SamplerPreset(name: "Creative", temperature: 1.2, topP: 0.95, repeatPenalty: 1.05)
        context.insert(preset)
        try context.save()

        let presetID = preset.id
        let descriptor = FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == presetID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.name, "Creative")
        XCTAssertEqual(fetched0.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(fetched0.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(fetched0.repeatPenalty, 1.05, accuracy: 0.001)
    }

    // MARK: - Codable round-trip (APIEndpoint)

    func test_apiEndpoint_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let endpoint = APIEndpoint(
            name: "Local LM Studio",
            provider: .lmStudio,
            baseURL: "http://localhost:1234",
            modelName: "custom-model"
        )
        context.insert(endpoint)
        try context.save()

        let endpointID = endpoint.id
        let descriptor = FetchDescriptor<APIEndpoint>(
            predicate: #Predicate { $0.id == endpointID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.name, "Local LM Studio")
        XCTAssertEqual(fetched0.provider, .lmStudio)
        XCTAssertEqual(fetched0.baseURL, "http://localhost:1234")
        XCTAssertEqual(fetched0.modelName, "custom-model")
        XCTAssertTrue(fetched0.isEnabled)
    }

    // MARK: - makeInMemoryContainer helper

    func test_makeInMemoryContainer_usesMigrationPlan() throws {
        // The TestHelpers helper must delegate to ModelContainerFactory so that
        // test containers match the production configuration.
        let container = try makeInMemoryContainer()
        XCTAssertNotNil(container)

        // Verify all model types are reachable through the container.
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .assistant, content: "Test", sessionID: sessionID)
        context.insert(message)
        XCTAssertNoThrow(try context.save())
    }
}
