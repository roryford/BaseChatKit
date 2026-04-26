import Foundation
import BaseChatInference

public final class MCPToolSource: @unchecked Sendable {
    public let serverID: UUID
    public let displayName: String
    private let capabilitiesValue: MCPCapabilities
    private let toolNamespace: String?
    private let toolFilter: MCPToolFilter
    private let listTools: (@Sendable () async throws -> JSONSchemaValue?)?
    private let callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    private let storage: MCPToolSourceStorage
    @MainActor private var registeredRegistries: [ObjectIdentifier: ToolRegistry] = [:]
    @MainActor private var registeredNamesByRegistry: [ObjectIdentifier: Set<String>] = [:]

    public init(
        serverID: UUID,
        displayName: String,
        capabilities: MCPCapabilities = .init()
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.capabilitiesValue = capabilities
        self.toolNamespace = nil
        self.toolFilter = .allowAll
        self.listTools = nil
        self.callTool = nil
        self.storage = MCPToolSourceStorage(serverID: serverID, serverDisplayName: displayName, approvalPolicy: .perCall)
    }

    internal init(
        serverID: UUID,
        displayName: String,
        capabilities: MCPCapabilities,
        toolNamespace: String?,
        toolFilter: MCPToolFilter,
        approvalPolicy: MCPApprovalPolicy,
        listTools: (@Sendable () async throws -> JSONSchemaValue?)?,
        callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    ) {
        self.serverID = serverID
        self.displayName = displayName
        self.capabilitiesValue = capabilities
        self.toolNamespace = toolNamespace
        self.toolFilter = toolFilter
        self.listTools = listTools
        self.callTool = callTool
        self.storage = MCPToolSourceStorage(serverID: serverID, serverDisplayName: displayName, approvalPolicy: approvalPolicy)
    }

    public var capabilities: MCPCapabilities {
        get async { capabilitiesValue }
    }

    public func currentToolNames() async -> [String] {
        await storage.currentToolNames()
    }

    /// Returns the currently-registered tools whose JSON Schemas are compatible
    /// with Apple's Foundation Models tool surface.
    ///
    /// Foundation Models rejects schemas that use `oneOf`, `$ref`, or whose
    /// nesting exceeds a small depth. This query returns the namespaced names
    /// of tools whose schemas pass all three checks, sorted alphabetically.
    ///
    /// "Deep nesting" is defined as the maximum depth of nested `object`
    /// (`properties`) or `array` (`items`) descents within the schema.
    /// `maxDepth: 4` accepts e.g. `{type:object, properties:{x:{type:array,
    /// items:{type:object, properties:{y:{type:string}}}}}}` (depth 3) but
    /// rejects schemas that nest one level deeper. Depth is measured from the
    /// root schema (depth 1 = the root object), so a flat
    /// `{type:object, properties:{x:{type:string}}}` is depth 2.
    ///
    /// - Parameter maxDepth: Maximum allowed schema nesting depth. Defaults to
    ///   4, which empirically covers most well-formed MCP server tools while
    ///   rejecting recursive or deeply-nested OpenAPI-style schemas that
    ///   Foundation Models can't handle.
    public func foundationModelsCompatibleNames(maxDepth: Int = 4) async -> [String] {
        let tools = await storage.currentTools()
        return tools
            .filter { isFoundationModelsCompatible($0.inputSchema, maxDepth: maxDepth) }
            .map(\.namespacedName)
            .sorted()
    }

    /// Returns the subset of currently-registered tools that should be exposed
    /// to Apple's Foundation Models backend in a given turn.
    ///
    /// Composes ``foundationModelsCompatibleNames(maxDepth:)`` with a hard cap
    /// (defaulting to ``MCPToolFilter/foundationModelsToolCap``). When more
    /// compatible tools exist than the cap allows, the lexicographically-first
    /// `cap` names are returned — deterministic ordering keeps the UI's
    /// "X of Y enabled" count stable across refreshes.
    ///
    /// - Parameters:
    ///   - maxDepth: Forwarded to the schema-compatibility check.
    ///   - cap: Maximum number of tools to return. Defaults to 16.
    public func foundationModelsEnabledNames(
        maxDepth: Int = 4,
        cap: Int = MCPToolFilter.foundationModelsToolCap
    ) async -> [String] {
        let compatible = await foundationModelsCompatibleNames(maxDepth: maxDepth)
        guard cap >= 0 else { return [] }
        return Array(compatible.prefix(cap))
    }

    @MainActor public func register(in registry: ToolRegistry) async {
        if await storage.isEmpty(), listTools != nil {
            do {
                try await refreshTools()
            } catch {
                return
            }
        }
        let executors = await storage.executors()
        for executor in executors {
            registry.register(executor)
        }
        let key = ObjectIdentifier(registry)
        registeredRegistries[key] = registry
        registeredNamesByRegistry[key] = Set(executors.map(\.definition.name))
    }

    @MainActor public func unregister(from registry: ToolRegistry) async {
        let key = ObjectIdentifier(registry)
        let names: Set<String>
        if let existing = registeredNamesByRegistry.removeValue(forKey: key) {
            names = existing
        } else {
            names = Set(await storage.currentToolNames())
        }
        for name in names {
            registry.unregister(name: name)
        }
        registeredRegistries.removeValue(forKey: key)
    }

    public func refreshTools() async throws {
        _ = try await refreshToolsAndReturnDelta()
    }

    public func markApproved(toolName: String? = nil) async {
        await storage.markApproved(toolName: toolName)
    }

    public func invalidateApprovals(toolName: String? = nil) async {
        await storage.invalidateApprovals(toolName: toolName)
    }

    public func close() async {
        await MainActor.run {
            for (key, registry) in registeredRegistries {
                let names = registeredNamesByRegistry[key] ?? []
                for name in names {
                    registry.unregister(name: name)
                }
            }
            registeredRegistries.removeAll()
            registeredNamesByRegistry.removeAll()
        }
        await storage.removeAll()
    }

    internal func refreshToolsAndReturnDelta(
        invalidateApprovalsForChangedTools: Bool = false
    ) async throws -> MCPToolRefreshDelta {
        guard let listTools else { return .empty }
        let response = try await listTools()
        let parsed = try Self.parseToolsListResponse(response)
        let filtered = try applyFilterAndNamespace(tools: parsed)
        let delta = await storage.replaceTools(
            with: filtered,
            invalidateApprovalsForChangedTools: invalidateApprovalsForChangedTools,
            callTool: callTool
        )
        await updateRegisteredRegistries(delta: delta)
        return delta
    }

    private func applyFilterAndNamespace(tools: [MCPRemoteTool]) throws -> [MCPRemoteTool] {
        let filtered = tools.filter { toolFilter.includes(name: $0.originalName) }
        if filtered.count > toolFilter.maxToolCount {
            throw MCPError.tooManyTools(filtered.count)
        }

        let namespacePrefix = normalizedNamespace(toolNamespace)
        var seen: Set<String> = []
        return try filtered.map { tool in
            let namespacedName = namespacePrefix.map { "\($0)__\(tool.originalName)" } ?? tool.originalName
            let key = namespacedName.lowercased()
            if seen.contains(key) {
                throw MCPError.malformedMetadata("Duplicate tool name after namespacing: \(namespacedName)")
            }
            seen.insert(key)
            return MCPRemoteTool(
                originalName: tool.originalName,
                namespacedName: namespacedName,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        }
    }

    private func updateRegisteredRegistries(delta: MCPToolRefreshDelta) async {
        guard !(delta.upsertExecutors.isEmpty && delta.removedNames.isEmpty) else { return }

        await MainActor.run {
            for (key, registry) in registeredRegistries {
                for removedName in delta.removedNames {
                    registry.unregister(name: removedName)
                }
                for executor in delta.upsertExecutors {
                    registry.register(executor)
                }
                registeredNamesByRegistry[key] = Set(delta.allNames)
            }
        }
    }

    private static func parseToolsListResponse(_ response: JSONSchemaValue?) throws -> [MCPRemoteTool] {
        guard case .object(let root)? = response else {
            throw MCPError.malformedMetadata("tools/list response must be an object")
        }
        guard case .array(let toolValues)? = root["tools"] else {
            throw MCPError.malformedMetadata("tools/list response missing tools array")
        }
        return try toolValues.map { value in
            guard case .object(let object) = value else {
                throw MCPError.malformedMetadata("tools/list item must be an object")
            }
            guard case .string(let name)? = object["name"], !name.isEmpty else {
                throw MCPError.malformedMetadata("tools/list item missing name")
            }
            let description: String
            if case .string(let rawDescription)? = object["description"] {
                description = rawDescription
            } else {
                description = "MCP tool '\(name)'"
            }
            let schema: JSONSchemaValue
            if let inputSchema = object["inputSchema"] {
                schema = inputSchema
            } else if let parameters = object["parameters"] {
                schema = parameters
            } else {
                schema = .object([:])
            }
            return MCPRemoteTool(
                originalName: name,
                namespacedName: name,
                description: description,
                inputSchema: schema
            )
        }
    }
}

// MARK: - Internal model shared between MCPToolSource and MCPToolSourceStorage

struct MCPRemoteTool: Sendable, Equatable {
    let originalName: String
    let namespacedName: String
    let description: String
    let inputSchema: JSONSchemaValue
}

internal struct MCPToolRefreshDelta: Sendable {
    let addedNames: [String]
    let removedNames: [String]
    let updatedNames: [String]
    let allNames: [String]
    let upsertExecutors: [MCPToolExecutor]

    static let empty = MCPToolRefreshDelta(
        addedNames: [],
        removedNames: [],
        updatedNames: [],
        allNames: [],
        upsertExecutors: []
    )
}

// MARK: - Storage actor for MCPToolSource

private actor MCPToolSourceStorage {
    private let serverID: UUID
    private let serverDisplayName: String
    private let approvalPolicy: MCPApprovalPolicy
    private var executorsByStableKey: [String: MCPToolExecutor] = [:]
    private var toolsByStableKey: [String: MCPRemoteTool] = [:]
    private var approvedToolNames: Set<String> = []
    private var serverApproved = false
    private var turnApproved = false

    init(serverID: UUID, serverDisplayName: String, approvalPolicy: MCPApprovalPolicy) {
        self.serverID = serverID
        self.serverDisplayName = serverDisplayName
        self.approvalPolicy = approvalPolicy
    }

    func isEmpty() -> Bool {
        executorsByStableKey.isEmpty
    }

    func executors() -> [MCPToolExecutor] {
        executorsByStableKey.values.sorted { $0.definition.name < $1.definition.name }
    }

    func currentToolNames() -> [String] {
        executorsByStableKey.values.map(\.definition.name).sorted()
    }

    func currentTools() -> [MCPRemoteTool] {
        Array(toolsByStableKey.values)
    }

    func replaceTools(
        with tools: [MCPRemoteTool],
        invalidateApprovalsForChangedTools: Bool,
        callTool: (@Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?)?
    ) async -> MCPToolRefreshDelta {
        if approvalPolicy == .persistentForTool {
            let persisted = await MCPPersistentToolApprovalStore.shared.approvedToolNames(for: serverID)
            approvedToolNames.formUnion(persisted)
        }

        let previousExecutors = executorsByStableKey
        let previousTools = toolsByStableKey
        let previousKeys = Set(previousExecutors.keys)

        var nextExecutors: [String: MCPToolExecutor] = [:]
        var nextTools: [String: MCPRemoteTool] = [:]
        var updatedKeys: Set<String> = []

        for tool in tools {
            let stableKey = stableToolKey(for: tool.namespacedName)
            if let previousTool = previousTools[stableKey],
               previousTool.isSemanticallyEquivalent(to: tool),
               let previousExecutor = previousExecutors[stableKey] {
                nextExecutors[stableKey] = previousExecutor
                nextTools[stableKey] = previousTool
                continue
            }

            if previousTools[stableKey] != nil {
                updatedKeys.insert(stableKey)
            }

            let requiresApproval = approvalRequired(for: stableKey)
            let executor = MCPToolExecutor(
                definition: ToolDefinition(
                    name: tool.namespacedName,
                    description: tool.description,
                    parameters: tool.inputSchema
                ),
                serverDisplayName: serverDisplayName,
                remoteToolName: tool.originalName,
                requiresApproval: requiresApproval,
                toolApprovalDidSucceed: { [weak self] in
                    await self?.markApproved(toolName: tool.namespacedName)
                },
                callTool: callTool ?? { name, _ in
                    throw MCPError.toolNotFound(name)
                }
            )
            nextExecutors[stableKey] = executor
            nextTools[stableKey] = tool
        }

        let nextKeys = Set(nextExecutors.keys)
        let addedKeys = nextKeys.subtracting(previousKeys)
        let removedKeys = previousKeys.subtracting(nextKeys)
        let changedKeys = addedKeys.union(removedKeys).union(updatedKeys)

        approvedToolNames = approvedToolNames.filter { nextKeys.contains($0) }

        if invalidateApprovalsForChangedTools, changedKeys.isEmpty == false {
            switch approvalPolicy {
            case .perCall:
                break
            case .perTurn:
                turnApproved = false
            case .sessionForServer:
                serverApproved = false
            case .sessionForTool:
                approvedToolNames.subtract(updatedKeys)
                approvedToolNames.subtract(removedKeys)
            case .persistentForTool:
                approvedToolNames.subtract(updatedKeys)
                approvedToolNames.subtract(removedKeys)
                await MCPPersistentToolApprovalStore.shared.revoke(
                    toolNames: Array(updatedKeys.union(removedKeys)),
                    for: serverID
                )
            }
        }

        executorsByStableKey = nextExecutors
        toolsByStableKey = nextTools
        applyApprovalPolicy()

        let addedNames = addedKeys.compactMap { nextExecutors[$0]?.definition.name }.sorted()
        let removedNames = removedKeys.compactMap { previousExecutors[$0]?.definition.name }.sorted()
        let updatedNames = updatedKeys.compactMap { nextExecutors[$0]?.definition.name }.sorted()
        let allNames = nextExecutors.values.map(\.definition.name).sorted()
        let upsertKeys = addedKeys.union(updatedKeys)
        let upsertExecutors = upsertKeys.compactMap { nextExecutors[$0] }
            .sorted { $0.definition.name < $1.definition.name }

        return MCPToolRefreshDelta(
            addedNames: addedNames,
            removedNames: removedNames,
            updatedNames: updatedNames,
            allNames: allNames,
            upsertExecutors: upsertExecutors
        )
    }

    func markApproved(toolName: String?) async {
        switch approvalPolicy {
        case .perCall:
            return
        case .perTurn:
            turnApproved = true
        case .sessionForServer:
            serverApproved = true
        case .sessionForTool, .persistentForTool:
            if let toolName {
                let stableName = stableToolKey(for: toolName)
                approvedToolNames.insert(stableName)
                if approvalPolicy == .persistentForTool {
                    await MCPPersistentToolApprovalStore.shared.markApproved(toolName: stableName, for: serverID)
                }
            }
        }
        applyApprovalPolicy()
    }

    func invalidateApprovals(toolName: String?) async {
        switch approvalPolicy {
        case .perCall:
            return
        case .perTurn:
            turnApproved = false
        case .sessionForServer:
            serverApproved = false
        case .sessionForTool, .persistentForTool:
            if let toolName {
                let stableName = stableToolKey(for: toolName)
                approvedToolNames.remove(stableName)
                if approvalPolicy == .persistentForTool {
                    await MCPPersistentToolApprovalStore.shared.revoke(toolName: stableName, for: serverID)
                }
            } else {
                approvedToolNames.removeAll()
                if approvalPolicy == .persistentForTool {
                    await MCPPersistentToolApprovalStore.shared.revokeAll(for: serverID)
                }
            }
        }
        applyApprovalPolicy()
    }

    func removeAll() {
        executorsByStableKey.removeAll()
        toolsByStableKey.removeAll()
        approvedToolNames.removeAll()
        serverApproved = false
        turnApproved = false
    }

    private func applyApprovalPolicy() {
        for (stableKey, executor) in executorsByStableKey {
            executor.setRequiresApproval(approvalRequired(for: stableKey))
        }
    }

    private func approvalRequired(for stableToolName: String) -> Bool {
        switch approvalPolicy {
        case .perCall:
            return true
        case .perTurn:
            return turnApproved == false
        case .sessionForTool, .persistentForTool:
            return approvedToolNames.contains(stableToolName) == false
        case .sessionForServer:
            return serverApproved == false
        }
    }
}

private actor MCPPersistentToolApprovalStore {
    static let shared = MCPPersistentToolApprovalStore()

    private var approvedByServer: [UUID: Set<String>] = [:]

    func approvedToolNames(for serverID: UUID) -> Set<String> {
        approvedByServer[serverID, default: []]
    }

    func markApproved(toolName: String, for serverID: UUID) {
        approvedByServer[serverID, default: []].insert(toolName)
    }

    func revoke(toolName: String, for serverID: UUID) {
        approvedByServer[serverID, default: []].remove(toolName)
    }

    func revoke(toolNames: [String], for serverID: UUID) {
        for name in toolNames {
            approvedByServer[serverID, default: []].remove(name)
        }
    }

    func revokeAll(for serverID: UUID) {
        approvedByServer[serverID] = []
    }
}

private func stableToolKey(for toolName: String) -> String {
    toolName.lowercased()
}

private extension MCPRemoteTool {
    func isSemanticallyEquivalent(to other: MCPRemoteTool) -> Bool {
        namespacedName.compare(other.namespacedName, options: .caseInsensitive) == .orderedSame &&
            originalName.compare(other.originalName, options: .caseInsensitive) == .orderedSame &&
            description == other.description &&
            inputSchema == other.inputSchema
    }
}

private func normalizedNamespace(_ namespace: String?) -> String? {
    guard let namespace else { return nil }
    let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Dots and whitespace are invalid in OpenAI tool names — replace with underscores.
    let normalized = trimmed
        .replacingOccurrences(of: ".", with: "_")
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: "_")
    return normalized.isEmpty ? nil : normalized
}

// MARK: - Foundation Models schema compatibility

/// Returns `true` when `schema` contains no `oneOf`, no `$ref`, and no nested
/// `object`/`array` chain deeper than `maxDepth` levels.
///
/// Internal so tests in the same module can exercise edge cases directly.
internal func isFoundationModelsCompatible(_ schema: JSONSchemaValue, maxDepth: Int) -> Bool {
    schemaDepthIfCompatible(schema, currentDepth: 1, maxDepth: maxDepth) != nil
}

/// Recursive walker. Returns `nil` the moment an unsupported construct is
/// found (rejecting the whole schema); otherwise returns the maximum depth
/// reached. The depth is "interesting" only as a guard against the recursive
/// case — callers just look at `nil` vs `non-nil`.
private func schemaDepthIfCompatible(
    _ schema: JSONSchemaValue,
    currentDepth: Int,
    maxDepth: Int
) -> Int? {
    if currentDepth > maxDepth { return nil }

    switch schema {
    case .object(let object):
        // Reject the constructs Foundation Models can't decode at any level.
        if object["oneOf"] != nil { return nil }
        if object["$ref"] != nil { return nil }
        // anyOf is also not in Apple's accepted vocabulary; reject it for symmetry
        // since it's structurally the same hazard as oneOf.
        if object["anyOf"] != nil { return nil }

        var deepest = currentDepth
        // Descend into properties (nested objects) and items (nested arrays).
        // Other keys (`type`, `description`, `required`, `enum`, etc.) are scalar
        // metadata that can't contain further schema nodes.
        if case .object(let properties)? = object["properties"] {
            for (_, child) in properties {
                guard let childDepth = schemaDepthIfCompatible(
                    child,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth
                ) else { return nil }
                deepest = max(deepest, childDepth)
            }
        }
        if let items = object["items"] {
            // `items` may be a single schema or an array of schemas (tuple form).
            switch items {
            case .array(let tupleItems):
                for child in tupleItems {
                    guard let childDepth = schemaDepthIfCompatible(
                        child,
                        currentDepth: currentDepth + 1,
                        maxDepth: maxDepth
                    ) else { return nil }
                    deepest = max(deepest, childDepth)
                }
            default:
                guard let childDepth = schemaDepthIfCompatible(
                    items,
                    currentDepth: currentDepth + 1,
                    maxDepth: maxDepth
                ) else { return nil }
                deepest = max(deepest, childDepth)
            }
        }
        return deepest
    case .array(let elements):
        // A bare schema array (rare at the top level but allowed inside e.g.
        // `prefixItems`) — descend without advancing depth, since we already
        // counted the array container at the parent.
        var deepest = currentDepth
        for element in elements {
            guard let childDepth = schemaDepthIfCompatible(
                element,
                currentDepth: currentDepth,
                maxDepth: maxDepth
            ) else { return nil }
            deepest = max(deepest, childDepth)
        }
        return deepest
    case .string, .number, .bool, .null:
        return currentDepth
    }
}

private extension MCPToolFilter {
    func includes(name: String) -> Bool {
        let normalizedSet = Set(names.map { $0.lowercased() })
        switch mode {
        case .allowAll:
            return true
        case .allowList:
            return normalizedSet.contains(name.lowercased())
        case .denyList:
            return normalizedSet.contains(name.lowercased()) == false
        }
    }
}
