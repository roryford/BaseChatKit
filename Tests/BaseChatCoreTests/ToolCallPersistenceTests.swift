import XCTest
import SwiftData
@testable import BaseChatCore

/// Verifies that ``ToolCallApprovalState`` round-trips through SwiftData so
/// chat history reloads preserve whether a call was approved, edited, or
/// rejected. The state is persisted inside the JSON payload stored in
/// ``ChatMessage.contentPartsJSON``, not a separate column, so these tests
/// double as a contract for the custom ``MessagePart`` Codable.
final class ToolCallPersistenceTests: XCTestCase {

    // MARK: - Codable round-trip

    func test_toolCallPart_withPendingState_roundTrips() throws {
        let part = MessagePart.toolCall(
            id: "call_1",
            name: "send_email",
            arguments: #"{"to":"a@b.com"}"#,
            state: .pending
        )
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_toolCallPart_withRejectedState_roundTrips() throws {
        let part = MessagePart.toolCall(
            id: "call_2",
            name: "delete_file",
            arguments: #"{"path":"/tmp/x"}"#,
            state: .rejected
        )
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_toolCallPart_withEditedState_roundTrips() throws {
        let part = MessagePart.toolCall(
            id: "call_3",
            name: "http_get",
            arguments: #"{"url":"https://example.com"}"#,
            state: .edited
        )
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    // MARK: - Backward compatibility

    func test_legacyPayloadWithoutStateField_decodesAsApproved() throws {
        // Synthesised Swift enum encoding used before the state field existed.
        let legacy = #"[{"toolCall":{"id":"x","name":"fn","arguments":"{}"}}]"#
        let data = Data(legacy.utf8)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(
            decoded,
            [.toolCall(id: "x", name: "fn", arguments: "{}", state: .approved)]
        )
    }

    // MARK: - SwiftData round-trip

    @MainActor
    func test_swiftData_toolCallStatePersistsAcrossFetch() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let parts: [MessagePart] = [
            .text("I should ask first."),
            .toolCall(id: "tc1", name: "delete_file", arguments: #"{"path":"/tmp/x"}"#, state: .pending)
        ]
        let message = ChatMessage(role: .assistant, contentParts: parts, sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Refetch from SwiftData — not just re-read the property.
        let fetched = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.contentParts, parts)
    }

    @MainActor
    func test_swiftData_pendingToApproved_persists() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let pending: [MessagePart] = [
            .toolCall(id: "tc1", name: "ping", arguments: "{}", state: .pending)
        ]
        let message = ChatMessage(role: .assistant, contentParts: pending, sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Mutate in place — the UI layer does this when the coordinator
        // resolves a pending call.
        message.contentParts = [
            .toolCall(id: "tc1", name: "ping", arguments: "{}", state: .approved)
        ]
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<ChatMessage>())
        guard case .toolCall(_, _, _, let state) = reloaded.first?.contentParts.first else {
            XCTFail("Expected toolCall part")
            return
        }
        XCTAssertEqual(state, .approved)
    }

    @MainActor
    func test_swiftData_pendingToRejected_persists() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let pending: [MessagePart] = [
            .toolCall(id: "tc1", name: "rm_rf", arguments: "{}", state: .pending)
        ]
        let message = ChatMessage(role: .assistant, contentParts: pending, sessionID: sessionID)
        context.insert(message)
        try context.save()

        message.contentParts = [
            .toolCall(id: "tc1", name: "rm_rf", arguments: "{}", state: .rejected),
            .toolResult(id: "tc1", content: "User rejected this tool call.")
        ]
        try context.save()

        let reloaded = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(reloaded.first?.contentParts.count, 2)
        if case .toolCall(_, _, _, let state) = reloaded.first?.contentParts.first {
            XCTAssertEqual(state, .rejected)
        } else {
            XCTFail("Expected first part to be a toolCall")
        }
    }
}
