import Foundation
import XCTest
@testable import BaseChatMCP
import BaseChatInference

@MainActor
final class MCPToolBridgeTests: XCTestCase {
    func test_perCallApprovalPolicyAlwaysRequiresApproval() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .perCall,
            toolNames: ["search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        await source.markApproved(toolName: "search")
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
    }

    func test_perTurnApprovalPolicyCanBeInvalidated() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .perTurn,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))

        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertFalse(registry.requiresApproval(toolName: "lookup"))

        await source.invalidateApprovals()
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))
    }

    func test_sessionForServerApprovalPolicyApprovesAllTools() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForServer,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))

        await source.markApproved()
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertFalse(registry.requiresApproval(toolName: "lookup"))
    }

    func test_sessionForToolApprovalPolicyOnlyApprovesNamedTool() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["search", "lookup"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
        XCTAssertTrue(registry.requiresApproval(toolName: "lookup"))
    }

    func test_persistentForToolApprovalPolicyPersistsAcrossSourcesForServer() async {
        let serverID = UUID()
        let first = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let firstRegistry = ToolRegistry()
        await first.register(in: firstRegistry)
        XCTAssertTrue(firstRegistry.requiresApproval(toolName: "search"))
        await first.markApproved(toolName: "search")
        XCTAssertFalse(firstRegistry.requiresApproval(toolName: "search"))
        await first.close()

        let second = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let secondRegistry = ToolRegistry()
        await second.register(in: secondRegistry)
        XCTAssertFalse(secondRegistry.requiresApproval(toolName: "search"))

        await second.invalidateApprovals(toolName: "search")
        XCTAssertTrue(secondRegistry.requiresApproval(toolName: "search"))
    }

    func test_sourceRegistersNamespacedFilteredToolsAndUnregisters() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: "docs",
            toolFilter: .init(mode: .allowList, names: ["search"]),
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object([
                            "name": .string("search"),
                            "description": .string("Search docs"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                        .object([
                            "name": .string("write"),
                            "description": .string("Write docs"),
                            "inputSchema": .object(["type": .string("object")]),
                        ]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()

        await source.register(in: registry)
        let namesAfterRegister = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(namesAfterRegister, ["docs.search"])

        await source.unregister(from: registry)
        let namesAfterUnregister = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertTrue(namesAfterUnregister.isEmpty)
    }

    func test_refreshUpdatesAlreadyRegisteredTools() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([
                    .object([
                        "name": .string("search"),
                        "inputSchema": .object(["type": .string("object")]),
                    ]),
                ]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: {
                await provider.value
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()

        await source.register(in: registry)
        await provider.setValue(.object([
            "tools": .array([
                .object([
                    "name": .string("lookup"),
                    "inputSchema": .object(["type": .string("object")]),
                ]),
            ]),
        ]))
        try await source.refreshTools()

        let names = await MainActor.run { registry.definitions.map(\.name) }
        XCTAssertEqual(names, ["lookup"])
    }

    func test_refreshHonorsMaxToolCount() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .init(mode: .allowAll, maxToolCount: 1),
            approvalPolicy: .perCall,
            listTools: {
                .object([
                    "tools": .array([
                        .object(["name": .string("a"), "inputSchema": .object([:])]),
                        .object(["name": .string("b"), "inputSchema": .object([:])]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )

        do {
            try await source.refreshTools()
            XCTFail("Expected tooManyTools error")
        } catch let error as MCPError {
            XCTAssertEqual(error, .tooManyTools(2))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_sessionForToolApprovalPolicyCanBeInvalidated() async {
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .sessionForTool,
            listTools: {
                .object([
                    "tools": .array([
                        .object(["name": .string("search"), "inputSchema": .object([:])]),
                    ]),
                ])
            },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        let beforeApproval = registry.requiresApproval(toolName: "search")
        XCTAssertTrue(beforeApproval)

        await source.markApproved(toolName: "search")
        let afterApproval = registry.requiresApproval(toolName: "search")
        XCTAssertFalse(afterApproval)

        await source.invalidateApprovals(toolName: "search")
        let afterInvalidation = registry.requiresApproval(toolName: "search")
        XCTAssertTrue(afterInvalidation)
    }

    func test_policyKeyingIsCaseInsensitive() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["Docs.Search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "docs.search"))
        await source.markApproved(toolName: "DOCS.SEARCH")
        XCTAssertFalse(registry.requiresApproval(toolName: "docs.search"))
        await source.invalidateApprovals(toolName: "DoCs.SeArCh")
        XCTAssertTrue(registry.requiresApproval(toolName: "docs.search"))
    }

    func test_refreshDoesNotChurnToolsForCaseOnlyNameChanges() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object([
                    "name": .string("Search"),
                    "description": .string("case-insensitive lookup"),
                    "inputSchema": .object([:]),
                ])]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .perCall,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )

        _ = try await source.refreshToolsAndReturnDelta()
        await provider.setValue(.object([
            "tools": .array([.object([
                "name": .string("search"),
                "description": .string("case-insensitive lookup"),
                "inputSchema": .object([:]),
            ])]),
        ]))

        let delta = try await source.refreshToolsAndReturnDelta()
        XCTAssertEqual(delta.addedNames, [])
        XCTAssertEqual(delta.removedNames, [])
        XCTAssertEqual(delta.updatedNames, [])
    }

    func test_listChangedInvalidatesSessionForServerApprovals() async throws {
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object(["name": .string("search"), "inputSchema": .object([:])])]),
            ])
        )
        let source = MCPToolSource(
            serverID: UUID(),
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .sessionForServer,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)
        await source.markApproved()
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))

        await provider.setValue(.object([
            "tools": .array([.object(["name": .string("search"), "description": .string("changed"), "inputSchema": .object([:])])]),
        ]))
        _ = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
    }

    func test_listChangedInvalidatesSessionAndPersistentToolApprovalsForChangedTool() async throws {
        let serverID = UUID()
        let provider = ToolListProvider(
            value: .object([
                "tools": .array([.object(["name": .string("search"), "inputSchema": .object([:])])]),
            ])
        )
        let source = MCPToolSource(
            serverID: serverID,
            displayName: "Docs",
            capabilities: .init(),
            toolNamespace: nil,
            toolFilter: .allowAll,
            approvalPolicy: .persistentForTool,
            listTools: { await provider.value },
            callTool: { _, _ in nil }
        )
        let registry = ToolRegistry()
        await source.register(in: registry)
        await source.markApproved(toolName: "search")
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))

        await provider.setValue(.object([
            "tools": .array([.object(["name": .string("search"), "description": .string("changed"), "inputSchema": .object([:])])]),
        ]))
        _ = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)
        XCTAssertTrue(registry.requiresApproval(toolName: "search"))

        await source.close()
        let reconnected = makeSource(
            serverID: serverID,
            approvalPolicy: .persistentForTool,
            toolNames: ["search"]
        )
        let reconnectRegistry = ToolRegistry()
        await reconnected.register(in: reconnectRegistry)
        XCTAssertTrue(reconnectRegistry.requiresApproval(toolName: "search"))
    }

    func test_dispatchingMCPToolRecordsApprovalForSessionPolicies() async {
        let source = makeSource(
            serverID: UUID(),
            approvalPolicy: .sessionForTool,
            toolNames: ["search"]
        )
        let registry = ToolRegistry()
        await source.register(in: registry)

        XCTAssertTrue(registry.requiresApproval(toolName: "search"))
        _ = await registry.dispatch(.init(id: "1", toolName: "search", arguments: "{}"))
        XCTAssertFalse(registry.requiresApproval(toolName: "search"))
    }

    func test_executorMapsStructuredErrorAndSanitizesContent() async throws {
        let executor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                .object([
                    "isError": .bool(true),
                    "errorKind": .string("permissionDenied"),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string("denied\u{0000}"),
                        ]),
                    ]),
                ])
            }
        )

        let result = try await executor.execute(arguments: .object([:]))
        XCTAssertEqual(result.errorKind, .permissionDenied)
        XCTAssertEqual(result.content, "denied")
    }

    func test_executorMapsMCPErrorKinds() async throws {
        let timeoutExecutor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                throw MCPError.requestTimeout
            }
        )
        let timeoutResult = try await timeoutExecutor.execute(arguments: .object([:]))
        XCTAssertEqual(timeoutResult.errorKind, .timeout)

        let cancelExecutor = MCPToolExecutor(
            definition: ToolDefinition(name: "docs.search", description: "Search", parameters: .object([:])),
            remoteToolName: "search",
            requiresApproval: true,
            callTool: { _, _ in
                try Task.checkCancellation()
                return .null
            }
        )
        let task = Task { try await cancelExecutor.execute(arguments: .object([:])) }
        task.cancel()
        let cancelledResult = try await task.value
        XCTAssertEqual(cancelledResult.errorKind, .cancelled)
    }
}

private func makeSource(
    serverID: UUID,
    approvalPolicy: MCPApprovalPolicy,
    toolNames: [String]
) -> MCPToolSource {
    MCPToolSource(
        serverID: serverID,
        displayName: "Docs",
        capabilities: .init(),
        toolNamespace: nil,
        toolFilter: .allowAll,
        approvalPolicy: approvalPolicy,
        listTools: {
            .object([
                "tools": .array(toolNames.map { .object(["name": .string($0), "inputSchema": .object([:])]) }),
            ])
        },
        callTool: { _, _ in nil }
    )
}

private actor ToolListProvider {
    var value: JSONSchemaValue?

    init(value: JSONSchemaValue?) {
        self.value = value
    }

    func setValue(_ value: JSONSchemaValue?) {
        self.value = value
    }
}
