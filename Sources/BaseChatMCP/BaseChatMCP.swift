import Foundation
import Security
import CryptoKit
import BaseChatInference

public struct MCPServerDescriptor: Sendable, Equatable, Hashable, Codable {
    public let id: UUID
    public let displayName: String
    public let transport: MCPTransportKind
    public let authorization: MCPAuthorizationDescriptor
    public let toolNamespace: String?
    public let resourceURL: URL?
    public let initializationTimeout: Duration
    public let dataDisclosure: String
    public let toolFilter: MCPToolFilter
    public let approvalPolicy: MCPApprovalPolicy

    public init(
        id: UUID = UUID(),
        displayName: String,
        transport: MCPTransportKind,
        authorization: MCPAuthorizationDescriptor = .none,
        toolNamespace: String? = nil,
        resourceURL: URL? = nil,
        initializationTimeout: Duration = .seconds(30),
        dataDisclosure: String,
        toolFilter: MCPToolFilter = .allowAll,
        approvalPolicy: MCPApprovalPolicy = .perCall
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.authorization = authorization
        self.toolNamespace = toolNamespace
        self.resourceURL = resourceURL
        self.initializationTimeout = initializationTimeout
        self.dataDisclosure = dataDisclosure
        self.toolFilter = toolFilter
        self.approvalPolicy = approvalPolicy
    }
}

public enum MCPTransportKind: Sendable, Equatable, Hashable, Codable {
    case stdio(MCPStdioCommand)
    case streamableHTTP(endpoint: URL, headers: [String: String])
}

public struct MCPStdioCommand: Sendable, Equatable, Hashable, Codable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public static func npx(package: String, args: [String] = []) -> Self {
        .init(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx", "-y", package] + args
        )
    }

    public static func executable(at url: URL, args: [String] = []) -> Self {
        .init(executable: url, arguments: args)
    }
}

public enum MCPAuthorizationDescriptor: Sendable, Equatable, Hashable, Codable {
    case none
    case oauth(OAuthDescriptor)

    public struct OAuthDescriptor: Sendable, Equatable, Hashable, Codable {
        public let clientName: String
        public let scopes: [String]
        public let redirectURI: URL
        public let authorizationServerIssuer: URL?
        public let softwareID: String?
        public let allowDynamicClientRegistration: Bool
        public let publicClient: Bool

        public init(
            clientName: String,
            scopes: [String],
            redirectURI: URL,
            authorizationServerIssuer: URL? = nil,
            softwareID: String? = nil,
            allowDynamicClientRegistration: Bool = true,
            publicClient: Bool = true
        ) {
            self.clientName = clientName
            self.scopes = scopes
            self.redirectURI = redirectURI
            self.authorizationServerIssuer = authorizationServerIssuer
            self.softwareID = softwareID
            self.allowDynamicClientRegistration = allowDynamicClientRegistration
            self.publicClient = publicClient
        }
    }
}

public struct MCPToolFilter: Sendable, Equatable, Hashable, Codable {
    public enum Mode: String, Sendable, Equatable, Hashable, Codable {
        case allowAll
        case allowList
        case denyList
    }

    public let mode: Mode
    public let names: [String]
    public let maxToolCount: Int

    public init(mode: Mode, names: [String] = [], maxToolCount: Int = 25) {
        self.mode = mode
        self.names = names
        self.maxToolCount = maxToolCount
    }

    public static var allowAll: Self { .init(mode: .allowAll) }
}

public struct MCPClientConfiguration: Sendable {
    public var sseStreamLimits: SSEStreamLimits
    public var requestTimeout: Duration
    public var maxConcurrentRequestsPerSession: Int
    public var maxMessageBytes: Int
    public var maxJSONNestingDepth: Int
    public var keychain: MCPKeychainConfiguration
    public var lifecyclePolicy: MCPSessionLifecyclePolicy
    public var networkPathObserver: (any MCPNetworkPathObserver)?
    public var lifecycleObserver: (any MCPLifecycleEventObserver)?

    public init(
        sseStreamLimits: SSEStreamLimits = BaseChatConfiguration.shared.sseStreamLimits,
        requestTimeout: Duration = .seconds(30),
        maxConcurrentRequestsPerSession: Int = 16,
        maxMessageBytes: Int = 4 * 1024 * 1024,
        maxJSONNestingDepth: Int = 32,
        keychain: MCPKeychainConfiguration = .init(),
        lifecyclePolicy: MCPSessionLifecyclePolicy = .cancelOnBackground,
        networkPathObserver: (any MCPNetworkPathObserver)? = nil,
        lifecycleObserver: (any MCPLifecycleEventObserver)? = nil
    ) {
        self.sseStreamLimits = sseStreamLimits
        self.requestTimeout = requestTimeout
        self.maxConcurrentRequestsPerSession = maxConcurrentRequestsPerSession
        self.maxMessageBytes = maxMessageBytes
        self.maxJSONNestingDepth = maxJSONNestingDepth
        self.keychain = keychain
        self.lifecyclePolicy = lifecyclePolicy
        self.networkPathObserver = networkPathObserver
        self.lifecycleObserver = lifecycleObserver
    }
}

public struct MCPKeychainConfiguration: @unchecked Sendable {
    public let accessGroup: String?
    public let accessibility: CFString

    public init(
        accessGroup: String? = nil,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }
}

public enum MCPSessionLifecyclePolicy: Sendable, Equatable, Hashable {
    case cancelOnBackground
    case detachAndResumeOnForeground
}

public enum MCPNetworkPathStatus: Sendable, Equatable, Hashable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

public protocol MCPNetworkPathObserver: Sendable {
    var pathUpdates: AsyncStream<MCPNetworkPathStatus> { get }
}

public enum MCPLifecycleEvent: Sendable, Equatable, Hashable {
    case didEnterBackground
    case willEnterForeground
    case memoryWarning
}

public protocol MCPLifecycleEventObserver: Sendable {
    var events: AsyncStream<MCPLifecycleEvent> { get }
}

public struct MCPCapabilities: Sendable, Equatable, Codable {
    public let protocolVersion: String
    public let serverName: String
    public let serverVersion: String
    public let supportsToolListChanged: Bool
    public let supportsResources: Bool
    public let supportsPrompts: Bool
    public let supportsLogging: Bool

    public init(
        protocolVersion: String = "2025-03-26",
        serverName: String = "",
        serverVersion: String = "",
        supportsToolListChanged: Bool = true,
        supportsResources: Bool = false,
        supportsPrompts: Bool = false,
        supportsLogging: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.supportsToolListChanged = supportsToolListChanged
        self.supportsResources = supportsResources
        self.supportsPrompts = supportsPrompts
        self.supportsLogging = supportsLogging
    }
}

public enum MCPConnectionEvent: Sendable {
    case connecting(serverID: UUID)
    case connected(serverID: UUID, capabilities: MCPCapabilities)
    case toolsChanged(serverID: UUID, addedNames: [String], removedNames: [String])
    case authorizationRequired(serverID: UUID, request: MCPAuthorizationRequest)
    case scopeDowngraded(serverID: UUID, requested: [String], granted: [String])
    case disconnected(serverID: UUID, reason: MCPDisconnectReason)
    case error(serverID: UUID, MCPError)
}

public enum MCPConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case ready
    case reconnecting
    case failed
}

public enum MCPDisconnectReason: Sendable, Equatable, Hashable, Codable {
    case requested
    case transportClosed
    case networkUnavailable
    case memoryPressure
    case unauthorized
    case failed(String)
}

public enum MCPError: Error, Sendable, Equatable {
    case transportClosed
    case transportFailure(String)
    case protocolError(code: Int, message: String, data: String?)
    case requestTimeout
    case unsupportedProtocolVersion(server: String, client: String)
    case authorizationRequired(MCPAuthorizationRequest)
    case authorizationFailed(String)
    case dcrFailed(String)
    case malformedMetadata(String)
    case issuerMismatch(expected: URL, actual: URL)
    case ssrfBlocked(URL)
    case tooManyTools(Int)
    case toolNotFound(String)
    case oversizeContent(Int)
    case oversizeMessage(Int)
    case networkUnavailable
    case unauthorized
    case failed(String)
    case backgroundedDuringDispatch
    case cancelled
}

public struct MCPAuthorizationRequest: Sendable, Equatable {
    public let serverID: UUID
    public let resourceMetadataURL: URL?
    public let authorizationServerURL: URL?
    public let requiredScopes: [String]

    public init(
        serverID: UUID,
        resourceMetadataURL: URL? = nil,
        authorizationServerURL: URL? = nil,
        requiredScopes: [String] = []
    ) {
        self.serverID = serverID
        self.resourceMetadataURL = resourceMetadataURL
        self.authorizationServerURL = authorizationServerURL
        self.requiredScopes = requiredScopes
    }
}

public protocol MCPAuthorization: Sendable {
    func authorizationHeader(for requestURL: URL) async throws -> String?
    func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision
}

public enum AuthRetryDecision: Sendable {
    case retry
    case fail(MCPError)
}

public struct MCPNoAuthorization: MCPAuthorization {
    public init() {}

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        _ = requestURL
        return nil
    }

    public func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = statusCode
        _ = body
        return .fail(.authorizationFailed("unauthorized"))
    }
}

public enum MCPApprovalPolicy: Sendable, Equatable, Hashable, Codable {
    case perCall
    case perTurn
    case sessionForTool
    case sessionForServer
    case persistentForTool
}

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
        self.storage = MCPToolSourceStorage(serverID: serverID, approvalPolicy: .perCall)
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
        self.storage = MCPToolSourceStorage(serverID: serverID, approvalPolicy: approvalPolicy)
    }

    public var capabilities: MCPCapabilities {
        get async { capabilitiesValue }
    }

    public func currentToolNames() async -> [String] {
        await storage.currentToolNames()
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
            let namespacedName = namespacePrefix.map { "\($0).\(tool.originalName)" } ?? tool.originalName
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

public final class MCPToolExecutor: ToolExecutor, @unchecked Sendable {
    public let definition: ToolDefinition
    private let remoteToolName: String
    private let callTool: @Sendable (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?
    private let toolApprovalDidSucceed: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var requiresApprovalValue: Bool

    public init(definition: ToolDefinition) {
        self.definition = definition
        self.remoteToolName = definition.name
        self.callTool = { name, _ in
            throw MCPError.toolNotFound(name)
        }
        self.toolApprovalDidSucceed = nil
        self.requiresApprovalValue = true
    }

    internal init(
        definition: ToolDefinition,
        remoteToolName: String,
        requiresApproval: Bool,
        toolApprovalDidSucceed: (@Sendable () async -> Void)? = nil,
        callTool: @Sendable @escaping (_ toolName: String, _ arguments: JSONSchemaValue) async throws -> JSONSchemaValue?
    ) {
        self.definition = definition
        self.remoteToolName = remoteToolName
        self.toolApprovalDidSucceed = toolApprovalDidSucceed
        self.callTool = callTool
        self.requiresApprovalValue = requiresApproval
    }

    public var requiresApproval: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requiresApprovalValue
    }

    public var supportsConcurrentDispatch: Bool { true }

    internal func setRequiresApproval(_ value: Bool) {
        lock.lock()
        requiresApprovalValue = value
        lock.unlock()
    }

    public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        do {
            try Task.checkCancellation()
            await toolApprovalDidSucceed?()
            let response = try await callTool(remoteToolName, arguments)
            try Task.checkCancellation()
            let parsed = Self.parseResult(response)
            return ToolResult(callId: "", content: Self.sanitize(parsed.content), errorKind: parsed.errorKind)
        } catch is CancellationError {
            return ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        } catch let error as MCPError {
            return ToolResult(
                callId: "",
                content: Self.sanitize(Self.message(for: error)),
                errorKind: Self.errorKind(for: error)
            )
        } catch {
            return ToolResult(callId: "", content: Self.sanitize(error.localizedDescription), errorKind: .permanent)
        }
    }

    private static func parseResult(_ value: JSONSchemaValue?) -> (content: String, errorKind: ToolResult.ErrorKind?) {
        guard let value else { return ("", nil) }
        guard case .object(let object) = value else {
            return (jsonString(from: value), nil)
        }

        let content = renderContent(from: object["content"] ?? value)
        if case .bool(true)? = object["isError"] {
            if case .string(let rawKind)? = object["errorKind"],
               let kind = ToolResult.ErrorKind(rawValue: rawKind) {
                return (content, kind)
            }
            return (content, .permanent)
        }
        return (content, nil)
    }

    private static func renderContent(from value: JSONSchemaValue) -> String {
        if case .string(let string) = value {
            return string
        }
        if case .array(let values) = value {
            let text = values.compactMap { item -> String? in
                guard case .object(let object) = item else { return nil }
                guard case .string(let type)? = object["type"], type == "text" else { return nil }
                guard case .string(let segment)? = object["text"] else { return nil }
                return segment
            }.joined(separator: "\n")
            if text.isEmpty == false { return text }
        }
        return jsonString(from: value)
    }

    private static func errorKind(for error: MCPError) -> ToolResult.ErrorKind {
        switch error {
        case .toolNotFound:
            return .unknownTool
        case .requestTimeout:
            return .timeout
        case .cancelled:
            return .cancelled
        case .authorizationRequired, .authorizationFailed, .unauthorized:
            return .permissionDenied
        case .transportClosed, .transportFailure, .networkUnavailable, .backgroundedDuringDispatch:
            return .transient
        case .protocolError(let code, _, _):
            switch code {
            case -32601:
                return .unknownTool
            case -32602:
                return .invalidArguments
            default:
                return .permanent
            }
        default:
            return .permanent
        }
    }

    private static func message(for error: MCPError) -> String {
        switch error {
        case .transportClosed:
            return "transport closed"
        case .transportFailure(let message),
             .authorizationFailed(let message),
             .dcrFailed(let message),
             .malformedMetadata(let message),
             .failed(let message):
            return message
        case .protocolError(_, let message, _):
            return message
        case .requestTimeout:
            return "request timed out"
        case .unsupportedProtocolVersion(let server, let client):
            return "unsupported protocol version server=\(server) client=\(client)"
        case .authorizationRequired:
            return "authorization required"
        case .issuerMismatch(let expected, let actual):
            return "issuer mismatch expected=\(expected.absoluteString) actual=\(actual.absoluteString)"
        case .ssrfBlocked(let url):
            return "ssrf blocked \(url.absoluteString)"
        case .tooManyTools(let count):
            return "too many tools (\(count))"
        case .toolNotFound(let name):
            return "tool not found: \(name)"
        case .oversizeContent(let bytes):
            return "oversize content \(bytes)"
        case .oversizeMessage(let bytes):
            return "oversize message \(bytes)"
        case .backgroundedDuringDispatch:
            return "backgrounded during dispatch"
        case .cancelled:
            return "cancelled by user"
        case .networkUnavailable:
            return "network unavailable"
        case .unauthorized:
            return "unauthorized"
        }
    }

    private static func sanitize(_ value: String, limit: Int = 8_192) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar.value == 10 || scalar.value == 13 || scalar.value == 9
            }
            return true
        }
        let string = String(String.UnicodeScalarView(filtered))
        if string.count <= limit {
            return string
        }
        return String(string.prefix(limit))
    }

    private static func jsonString(from value: JSONSchemaValue) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            if let string = String(data: data, encoding: .utf8) {
                return string
            }
        } catch {
            Log.inference.warning("MCPToolExecutor: failed to encode structured content as JSON string")
        }
        return ""
    }
}

private struct MCPRemoteTool: Sendable, Equatable {
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

private actor MCPToolSourceStorage {
    private let serverID: UUID
    private let approvalPolicy: MCPApprovalPolicy
    private var executorsByStableKey: [String: MCPToolExecutor] = [:]
    private var toolsByStableKey: [String: MCPRemoteTool] = [:]
    private var approvedToolNames: Set<String> = []
    private var serverApproved = false
    private var turnApproved = false

    init(serverID: UUID, approvalPolicy: MCPApprovalPolicy) {
        self.serverID = serverID
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

private final class MCPClientSessionHook: MCPSessionStateHook, @unchecked Sendable {
    weak var client: MCPClient?
    let serverID: UUID

    init(client: MCPClient, serverID: UUID) {
        self.client = client
        self.serverID = serverID
    }

    func sessionDidTransition(_ state: MCPSessionState) async {
        _ = state
    }

    func sessionDidSend(_ message: MCPJSONRPCMessage) async {
        _ = message
    }

    func sessionDidReceive(_ message: MCPJSONRPCMessage) async {
        guard case .notification = message else { return }
        await client?.handleSessionMessage(serverID: serverID, message: message)
    }
}

private final class WeakMCPClientBox: @unchecked Sendable {
    weak var client: MCPClient?

    init(client: MCPClient) {
        self.client = client
    }
}

private func normalizedNamespace(_ namespace: String?) -> String? {
    guard let namespace else { return nil }
    let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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

public actor MCPClient {
    public nonisolated let connectionEvents: AsyncStream<MCPConnectionEvent>
    public nonisolated let connectionState: AsyncStream<MCPConnectionState>

    private let configuration: MCPClientConfiguration
    private let connectionEventContinuation: AsyncStream<MCPConnectionEvent>.Continuation
    private let connectionStateContinuation: AsyncStream<MCPConnectionState>.Continuation
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var sessionsByID: [UUID: MCPSession] = [:]
    private var networkPathTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?

    public init(configuration: MCPClientConfiguration = .init()) {
        self.configuration = configuration
        var eventContinuation: AsyncStream<MCPConnectionEvent>.Continuation!
        var stateContinuation: AsyncStream<MCPConnectionState>.Continuation!
        connectionEvents = AsyncStream { continuation in
            eventContinuation = continuation
        }
        connectionState = AsyncStream { continuation in
            stateContinuation = continuation
        }
        connectionEventContinuation = eventContinuation
        connectionStateContinuation = stateContinuation
        connectionStateContinuation.yield(.idle)

        Task { await self.startObserverTasks() }
    }

    deinit {
        networkPathTask?.cancel()
        lifecycleTask?.cancel()
    }

    public func connect(
        _ descriptor: MCPServerDescriptor,
        authorization: any MCPAuthorization = MCPNoAuthorization()
    ) async throws -> MCPToolSource {
        connectionStateContinuation.yield(.connecting)
        connectionEventContinuation.yield(.connecting(serverID: descriptor.id))

        do {
            let transport = try makeTransport(for: descriptor, authorization: authorization)
            let stateHook = MCPClientSessionHook(client: self, serverID: descriptor.id)
            let session = MCPSession(
                descriptor: descriptor,
                transport: transport,
                codec: MCPJSONRPCCodec(
                    maxMessageBytes: configuration.maxMessageBytes,
                    maxJSONNestingDepth: configuration.maxJSONNestingDepth
                ),
                requestTimeout: descriptor.initializationTimeout,
                maxConcurrentRequests: configuration.maxConcurrentRequestsPerSession,
                stateHook: stateHook
            )

            let capabilities = try await session.start()
            let source = MCPToolSource(
                serverID: descriptor.id,
                displayName: descriptor.displayName,
                capabilities: capabilities,
                toolNamespace: descriptor.toolNamespace,
                toolFilter: descriptor.toolFilter,
                approvalPolicy: descriptor.approvalPolicy,
                listTools: { [session] in
                    try await session.sendRequest(method: "tools/list", params: nil)
                },
                callTool: { [session] toolName, arguments in
                    try await session.sendRequest(
                        method: "tools/call",
                        params: .object([
                            "name": .string(toolName),
                            "arguments": arguments,
                        ])
                    )
                }
            )
            sessionsByID[descriptor.id] = session
            sourcesByID[descriptor.id] = source
            connectionStateContinuation.yield(.ready)
            connectionEventContinuation.yield(.connected(serverID: descriptor.id, capabilities: capabilities))
            return source
        } catch let error as MCPError {
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, error))
            throw error
        } catch {
            let mcpError = MCPError.transportFailure(error.localizedDescription)
            connectionStateContinuation.yield(.failed)
            connectionEventContinuation.yield(.error(serverID: descriptor.id, mcpError))
            throw mcpError
        }
    }

    public func disconnect(serverID: UUID) async {
        if let session = sessionsByID.removeValue(forKey: serverID) {
            await session.close(reason: .requested)
        }
        if let source = sourcesByID.removeValue(forKey: serverID) {
            await source.close()
        }
        connectionEventContinuation.yield(.disconnected(serverID: serverID, reason: .requested))
        connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
    }

    public func disconnectAll() async {
        let sessions = sessionsByID.values
        sessionsByID.removeAll()
        for session in sessions {
            await session.close(reason: .requested)
        }
        let sources = sourcesByID.values
        sourcesByID.removeAll()
        for source in sources {
            await source.close()
        }
        connectionStateContinuation.yield(.idle)
    }

    public func sources() async -> [MCPToolSource] {
        Array(sourcesByID.values)
    }

    private func makeTransport(
        for descriptor: MCPServerDescriptor,
        authorization: any MCPAuthorization
    ) throws -> any MCPTransport {
        switch descriptor.transport {
        case .streamableHTTP(let endpoint, let headers):
            try MCPSSRFPolicy.validateTransportURL(endpoint)
            return MCPStreamableHTTPTransport(configuration: MCPTransportConfiguration(
                endpoint: endpoint,
                headers: headers,
                authorization: authorization,
                sseLimits: configuration.sseStreamLimits,
                maxMessageBytes: configuration.maxMessageBytes
            ))
        case .stdio(let command):
            #if os(macOS) && !targetEnvironment(macCatalyst)
            return MCPStdioTransport(
                command: command,
                maxMessageBytes: configuration.maxMessageBytes
            )
            #else
            throw MCPError.transportFailure("stdio MCP transport is unavailable on this platform")
            #endif
        }
    }

    internal func handleSessionMessage(serverID: UUID, message: MCPJSONRPCMessage) async {
        guard case .notification(let method, _) = message,
              method == "notifications/tools/list_changed",
              let source = sourcesByID[serverID] else {
            return
        }

        do {
            let delta = try await source.refreshToolsAndReturnDelta(invalidateApprovalsForChangedTools: true)
            if delta.addedNames.isEmpty == false || delta.removedNames.isEmpty == false {
                connectionEventContinuation.yield(.toolsChanged(
                    serverID: serverID,
                    addedNames: delta.addedNames,
                    removedNames: delta.removedNames
                ))
            }
        } catch let error as MCPError {
            connectionEventContinuation.yield(.error(serverID: serverID, error))
        } catch {
            connectionEventContinuation.yield(.error(serverID: serverID, .transportFailure(error.localizedDescription)))
        }
    }

    private func startObserverTasks() {
        let weakBox = WeakMCPClientBox(client: self)

        if let observer = configuration.networkPathObserver {
            let updates = observer.pathUpdates
            networkPathTask = Task {
                for await status in updates {
                    guard let client = weakBox.client else { return }
                    await client.handleNetworkPath(status)
                }
            }
        }

        if let observer = configuration.lifecycleObserver {
            let updates = observer.events
            lifecycleTask = Task {
                for await event in updates {
                    guard let client = weakBox.client else { return }
                    await client.handleLifecycleEvent(event)
                }
            }
        }
    }

    private func handleNetworkPath(_ status: MCPNetworkPathStatus) async {
        switch status {
        case .satisfied:
            connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
        case .unsatisfied, .requiresConnection:
            guard sessionsByID.isEmpty == false else {
                connectionStateContinuation.yield(.idle)
                return
            }
            connectionStateContinuation.yield(.reconnecting)
            await closeAllSessions(reason: .networkUnavailable, error: .networkUnavailable)
        }
    }

    private func handleLifecycleEvent(_ event: MCPLifecycleEvent) async {
        switch event {
        case .didEnterBackground:
            guard configuration.lifecyclePolicy == .cancelOnBackground else { return }
            guard sessionsByID.isEmpty == false else { return }
            await closeAllSessions(reason: .requested, error: .backgroundedDuringDispatch)
        case .willEnterForeground:
            connectionStateContinuation.yield(sourcesByID.isEmpty ? .idle : .ready)
        case .memoryWarning:
            guard sessionsByID.isEmpty == false else { return }
            await closeAllSessions(reason: .memoryPressure, error: .transportFailure("memory warning"))
        }
    }

    private func closeAllSessions(
        reason: MCPDisconnectReason,
        error: MCPError?
    ) async {
        let sessions = sessionsByID
        let sources = sourcesByID
        sessionsByID.removeAll()
        sourcesByID.removeAll()

        for (serverID, session) in sessions {
            await session.close(reason: reason)
            if let source = sources[serverID] {
                await source.close()
            }
            if let error {
                connectionEventContinuation.yield(.error(serverID: serverID, error))
            }
            connectionEventContinuation.yield(.disconnected(serverID: serverID, reason: reason))
        }

        connectionStateContinuation.yield(.idle)
    }
}

public protocol MCPOAuthRedirectListener: Sendable {
    func authorize(
        authorizationURL: URL,
        callbackURLScheme: String,
        prefersEphemeralSession: Bool
    ) async throws -> URL
}

public struct MCPOAuthTokens: Sendable, Codable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let tokenType: String
    public let issuer: URL
    public let subjectIdentifier: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        scopes: [String],
        tokenType: String = "Bearer",
        issuer: URL,
        subjectIdentifier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.tokenType = tokenType
        self.issuer = issuer
        self.subjectIdentifier = subjectIdentifier
    }
}

public struct MCPOAuthTokenStore: Sendable {
    public typealias Read = @Sendable (UUID) async throws -> MCPOAuthTokens?
    public typealias Write = @Sendable (MCPOAuthTokens, UUID) async throws -> Void
    public typealias Delete = @Sendable (UUID) async throws -> Void

    public let read: Read
    public let write: Write
    public let delete: Delete

    public init(read: @escaping Read, write: @escaping Write, delete: @escaping Delete) {
        self.read = read
        self.write = write
        self.delete = delete
    }

    public static let keychain = MCPOAuthTokenStore.inMemory()

    public static func inMemory() -> MCPOAuthTokenStore {
        actor Storage {
            var values: [UUID: MCPOAuthTokens] = [:]
            func read(_ id: UUID) -> MCPOAuthTokens? { values[id] }
            func write(_ tokens: MCPOAuthTokens, _ id: UUID) { values[id] = tokens }
            func delete(_ id: UUID) { values.removeValue(forKey: id) }
        }
        let storage = Storage()
        return .init(
            read: { id in await storage.read(id) },
            write: { tokens, id in await storage.write(tokens, id) },
            delete: { id in await storage.delete(id) }
        )
    }

    public static func custom(
        read: @escaping Read,
        write: @escaping Write,
        delete: @escaping Delete
    ) -> MCPOAuthTokenStore {
        .init(read: read, write: write, delete: delete)
    }
}

private struct OAuthProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    private enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

private struct OAuthAuthorizationServerMetadata: Decodable {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let scope: String?
    let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }
}

private struct OAuthTokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct OAuthDynamicClientRegistrationResponse: Decodable {
    let clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

public actor MCPOAuthAuthorization: MCPAuthorization {
    private let descriptor: MCPAuthorizationDescriptor.OAuthDescriptor
    private let serverID: UUID
    private let resourceURL: URL
    private let redirectListener: any MCPOAuthRedirectListener
    private let tokenStore: MCPOAuthTokenStore
    private let random: @Sendable () -> Data
    private let session: URLSession
    private let currentDate: @Sendable () -> Date

    private var cachedAuthorizationMetadata: OAuthAuthorizationServerMetadata?
    private var cachedResourceMetadataURL: URL?
    private var cachedRegisteredClientID: String?

    public init(
        descriptor: MCPAuthorizationDescriptor.OAuthDescriptor,
        serverID: UUID,
        resourceURL: URL,
        redirectListener: any MCPOAuthRedirectListener,
        tokenStore: MCPOAuthTokenStore = .keychain,
        clock: any Clock<Duration> = ContinuousClock(),
        random: @escaping @Sendable () -> Data = { Data() },
        session: URLSession = .shared,
        currentDate: @escaping @Sendable () -> Date = Date.init
    ) {
        self.descriptor = descriptor
        self.serverID = serverID
        self.resourceURL = resourceURL
        self.redirectListener = redirectListener
        self.tokenStore = tokenStore
        self.random = random
        self.session = session
        self.currentDate = currentDate
        _ = clock
    }

    public func authorizationHeader(for requestURL: URL) async throws -> String? {
        try MCPSSRFPolicy.validateOAuthURL(requestURL, label: "oauth request")
        guard Self.isSameOrigin(lhs: requestURL, rhs: resourceURL) else {
            return nil
        }

        let tokens = try await activeTokens()
        try validateBearerTransmission(tokens)
        return "\(tokens.tokenType) \(tokens.accessToken)"
    }

    public func handleUnauthorized(statusCode: Int, body: Data) async throws -> AuthRetryDecision {
        _ = body
        try MCPSSRFPolicy.validateOAuthURL(resourceURL, label: "resource")
        guard statusCode == 401 || statusCode == 403 else {
            return .fail(.authorizationFailed("unexpected status \(statusCode)"))
        }

        guard let existing = try await tokenStore.read(serverID) else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }
        guard let refreshToken = existing.refreshToken else {
            return .fail(.authorizationRequired(buildAuthorizationRequest()))
        }

        do {
            let metadata = try await discoverAuthorizationMetadata()
            let refreshed = try await exchangeRefreshToken(
                refreshToken,
                metadata: metadata,
                existing: existing
            )
            try await tokenStore.write(refreshed, serverID)
            return .retry
        } catch let error as MCPError {
            if case .authorizationRequired = error {
                do {
                    try await tokenStore.delete(serverID)
                } catch {
                    Log.inference.warning("MCPOAuthAuthorization: failed to clear token store after invalid_grant")
                }
            }
            return .fail(error)
        } catch {
            return .fail(.authorizationFailed(error.localizedDescription))
        }
    }

    private func activeTokens() async throws -> MCPOAuthTokens {
        if let stored = try await tokenStore.read(serverID) {
            try verifyIssuer(stored.issuer)
            if !isExpired(stored) {
                try validateBearerTransmission(stored)
                return stored
            }

            if let refreshToken = stored.refreshToken {
                do {
                    let metadata = try await discoverAuthorizationMetadata()
                    let refreshed = try await exchangeRefreshToken(
                        refreshToken,
                        metadata: metadata,
                        existing: stored
                    )
                    try await tokenStore.write(refreshed, serverID)
                    try validateBearerTransmission(refreshed)
                    return refreshed
                } catch {
                    try await tokenStore.delete(serverID)
                    Log.inference.warning("MCPOAuthAuthorization: refresh failed, forcing full OAuth authorization")
                }
            }
        }

        let metadata = try await discoverAuthorizationMetadata()
        let codeResponse = try await performAuthorizationCodeFlow(metadata: metadata)
        try await tokenStore.write(codeResponse, serverID)
        try validateBearerTransmission(codeResponse)
        return codeResponse
    }

    private func performAuthorizationCodeFlow(metadata: OAuthAuthorizationServerMetadata) async throws -> MCPOAuthTokens {
        let state = randomBase64URL(byteCount: 32)
        let verifier = randomBase64URL(byteCount: 48)
        let challenge = Self.pkceChallenge(for: verifier)
        let clientID = try await resolveClientIdentifier(metadata: metadata)

        let callbackScheme = try callbackScheme()
        let authorizationURL = try buildAuthorizationURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: clientID,
            state: state,
            verifierChallenge: challenge
        )
        let callbackURL = try await redirectListener.authorize(
            authorizationURL: authorizationURL,
            callbackURLScheme: callbackScheme,
            prefersEphemeralSession: true
        )

        let code = try parseAuthorizationCode(callbackURL: callbackURL, expectedState: state)
        return try await exchangeAuthorizationCode(
            code: code,
            verifier: verifier,
            clientID: clientID,
            metadata: metadata
        )
    }

    private func discoverAuthorizationMetadata() async throws -> OAuthAuthorizationServerMetadata {
        if let cachedAuthorizationMetadata {
            return cachedAuthorizationMetadata
        }

        let decoder = JSONDecoder()
        let issuer: URL
        if let explicitIssuer = descriptor.authorizationServerIssuer {
            issuer = explicitIssuer
            try enforceHTTPS(issuer, label: "authorization issuer")
        } else {
            let resourceMetadataURL = Self.resourceMetadataURL(for: resourceURL)
            try enforceHTTPS(resourceMetadataURL, label: "resource metadata")
            let (data, response) = try await session.data(for: URLRequest(url: resourceMetadataURL))
            try requireSuccess(response: response, body: data, operation: "resource metadata discovery")
            let resourceMetadata = try decoder.decode(OAuthProtectedResourceMetadata.self, from: data)
            guard let candidateIssuers = resourceMetadata.authorizationServers, candidateIssuers.isEmpty == false else {
                throw MCPError.malformedMetadata("Missing authorization_servers in resource metadata")
            }
            var discoveredIssuer: URL?
            var lastValidationError: Error?
            for candidate in candidateIssuers {
                do {
                    try enforceHTTPS(candidate, label: "authorization issuer")
                    discoveredIssuer = candidate
                    break
                } catch {
                    lastValidationError = error
                }
            }
            guard let discoveredIssuer else {
                if let lastValidationError {
                    throw lastValidationError
                }
                throw MCPError.malformedMetadata("Missing valid authorization server issuer")
            }
            issuer = discoveredIssuer
            cachedResourceMetadataURL = resourceMetadataURL
        }

        let metadataURL = Self.authorizationMetadataURL(for: issuer)
        try enforceHTTPS(metadataURL, label: "authorization metadata")
        let (metadataData, metadataResponse) = try await session.data(for: URLRequest(url: metadataURL))
        try requireSuccess(response: metadataResponse, body: metadataData, operation: "authorization metadata discovery")
        let metadata = try decoder.decode(OAuthAuthorizationServerMetadata.self, from: metadataData)
        try enforceHTTPS(metadata.authorizationEndpoint, label: "authorization endpoint")
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")

        if Self.isSameIssuer(metadata.issuer, issuer) == false {
            throw MCPError.issuerMismatch(expected: issuer, actual: metadata.issuer)
        }
        if let expectedIssuer = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(metadata.issuer, expectedIssuer) == false {
            throw MCPError.issuerMismatch(expected: expectedIssuer, actual: metadata.issuer)
        }

        cachedAuthorizationMetadata = metadata
        return metadata
    }

    private func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        clientID: String,
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": descriptor.redirectURI.absoluteString,
            "code_verifier": verifier,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        return try await tokenExchange(parameters: parameters, metadata: metadata)
    }

    private func exchangeRefreshToken(
        _ refreshToken: String,
        metadata: OAuthAuthorizationServerMetadata,
        existing: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        let clientID = try await resolveClientIdentifier(metadata: metadata)
        var parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        parameters["resource"] = resourceURL.absoluteString
        let refreshed = try await tokenExchange(parameters: parameters, metadata: metadata)
        return MCPOAuthTokens(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? existing.refreshToken,
            expiresAt: refreshed.expiresAt,
            scopes: refreshed.scopes,
            tokenType: refreshed.tokenType,
            issuer: refreshed.issuer,
            subjectIdentifier: refreshed.subjectIdentifier ?? existing.subjectIdentifier
        )
    }

    private func tokenExchange(
        parameters: [String: String],
        metadata: OAuthAuthorizationServerMetadata
    ) async throws -> MCPOAuthTokens {
        try enforceHTTPS(metadata.tokenEndpoint, label: "token endpoint")
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncoded(parameters).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during token exchange")
        }
        if (200...299).contains(http.statusCode) == false {
            throw parseTokenExchangeFailure(statusCode: http.statusCode, body: data)
        }

        let decoder = JSONDecoder()
        let parsed = try decoder.decode(OAuthTokenResponse.self, from: data)
        let scopes = parsed.scope?.split(separator: " ").map(String.init) ?? descriptor.scopes
        let expiresAt = parsed.expiresIn.map { currentDate().addingTimeInterval($0) }
        return MCPOAuthTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            tokenType: parsed.tokenType ?? "Bearer",
            issuer: metadata.issuer
        )
    }

    private func buildAuthorizationURL(
        endpoint: URL,
        clientID: String,
        state: String,
        verifierChallenge: String
    ) throws -> URL {
        try enforceHTTPS(endpoint, label: "authorization endpoint")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: descriptor.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: descriptor.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: verifierChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resourceURL.absoluteString),
        ])
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw MCPError.malformedMetadata("Could not build authorization URL")
        }
        return url
    }

    private func callbackScheme() throws -> String {
        guard let scheme = descriptor.redirectURI.scheme, !scheme.isEmpty else {
            throw MCPError.malformedMetadata("OAuth redirect URI must include a callback scheme")
        }
        return scheme
    }

    private func parseAuthorizationCode(callbackURL: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        if let errorValue = queryItems.first(where: { $0.name == "error" })?.value {
            throw MCPError.authorizationFailed(errorValue)
        }

        let state = queryItems.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw MCPError.authorizationFailed("OAuth state mismatch")
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MCPError.authorizationFailed("Missing authorization code in callback")
        }
        return code
    }

    private func verifyIssuer(_ issuer: URL) throws {
        if let expected = descriptor.authorizationServerIssuer,
           Self.isSameIssuer(expected, issuer) == false {
            throw MCPError.issuerMismatch(expected: expected, actual: issuer)
        }
    }

    private func isExpired(_ token: MCPOAuthTokens) -> Bool {
        guard let expiresAt = token.expiresAt else { return false }
        return expiresAt <= currentDate().addingTimeInterval(30)
    }

    private func randomBase64URL(byteCount: Int) -> String {
        let generated = random()
        let randomData = generated.isEmpty ? Self.secureRandomData(length: byteCount) : generated
        return Self.base64URL(randomData)
    }

    private func resolveClientIdentifier(metadata: OAuthAuthorizationServerMetadata) async throws -> String {
        if let cachedRegisteredClientID {
            return cachedRegisteredClientID
        }

        let fallbackClientID = clientIdentifier()
        guard descriptor.allowDynamicClientRegistration else {
            return fallbackClientID
        }
        guard let registrationEndpoint = metadata.registrationEndpoint else {
            return fallbackClientID
        }

        do {
            try enforceHTTPS(registrationEndpoint, label: "registration endpoint")
            var request = URLRequest(url: registrationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            var payload: [String: Any] = [
                "client_name": descriptor.clientName,
                "redirect_uris": [descriptor.redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"],
                "scope": descriptor.scopes.joined(separator: " ")
            ]
            if let softwareID = descriptor.softwareID, softwareID.isEmpty == false {
                payload["software_id"] = softwareID
            }
            if descriptor.publicClient {
                payload["token_endpoint_auth_method"] = "none"
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

            let (data, response) = try await session.data(for: request)
            try requireSuccess(response: response, body: data, operation: "dynamic client registration")
            let parsed = try JSONDecoder().decode(OAuthDynamicClientRegistrationResponse.self, from: data)
            guard parsed.clientID.isEmpty == false else {
                throw MCPError.dcrFailed("dynamic client registration did not return client_id")
            }
            cachedRegisteredClientID = parsed.clientID
            return parsed.clientID
        } catch {
            if descriptor.publicClient {
                Log.inference.warning("MCPOAuthAuthorization: DCR unavailable, falling back to static public client identifier")
                return fallbackClientID
            }
            throw MCPError.dcrFailed(error.localizedDescription)
        }
    }

    private func parseTokenExchangeFailure(statusCode: Int, body: Data) -> MCPError {
        do {
            let oauthError = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: body)
            if oauthError.error == "invalid_grant" {
                return .authorizationRequired(buildAuthorizationRequest())
            }
            let description = oauthError.errorDescription ?? oauthError.error
            return .authorizationFailed("token exchange failed (\(statusCode)): \(description)")
        } catch {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(statusCode)"
            return .authorizationFailed("token exchange failed (\(statusCode)): \(message)")
        }
    }

    private func validateBearerTransmission(_ tokens: MCPOAuthTokens) throws {
        guard tokens.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPError.authorizationFailed("Unsupported token type for Authorization header")
        }
        guard tokens.accessToken.isEmpty == false else {
            throw MCPError.authorizationFailed("Missing access token")
        }
        let invalidScalars = CharacterSet.controlCharacters
            .union(.newlines)
            .union(.whitespacesAndNewlines)
        if tokens.accessToken.unicodeScalars.contains(where: { invalidScalars.contains($0) }) {
            throw MCPError.authorizationFailed("Access token contains invalid bearer characters")
        }
    }

    private func buildAuthorizationRequest() -> MCPAuthorizationRequest {
        let metadataURL = cachedResourceMetadataURL ?? Self.resourceMetadataURL(for: resourceURL)
        let safeMetadataURL: URL?
        do {
            try MCPSSRFPolicy.validateOAuthURL(metadataURL, label: "resource metadata")
            safeMetadataURL = metadataURL
        } catch {
            safeMetadataURL = nil
            Log.inference.warning("MCPOAuthAuthorization: omitted unsafe resource metadata URL from auth request")
        }

        let safeAuthorizationURL: URL?
        if let issuer = descriptor.authorizationServerIssuer {
            do {
                try MCPSSRFPolicy.validateOAuthURL(issuer, label: "authorization issuer")
                safeAuthorizationURL = issuer
            } catch {
                safeAuthorizationURL = nil
                Log.inference.warning("MCPOAuthAuthorization: omitted unsafe authorization issuer URL from auth request")
            }
        } else {
            safeAuthorizationURL = nil
        }

        return MCPAuthorizationRequest(
            serverID: serverID,
            resourceMetadataURL: safeMetadataURL,
            authorizationServerURL: safeAuthorizationURL,
            requiredScopes: descriptor.scopes
        )
    }

    private func enforceHTTPS(_ url: URL, label: String) throws {
        try MCPSSRFPolicy.validateOAuthURL(url, label: label)
    }

    private func requireSuccess(response: URLResponse, body: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during \(operation)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MCPError.authorizationFailed("\(operation) failed: \(message)")
        }
    }

    private func clientIdentifier() -> String {
        descriptor.softwareID ?? descriptor.clientName
    }

    private static func authorizationMetadataURL(for issuer: URL) -> URL {
        let trimmedPath = issuer.path == "/" ? "" : issuer.path
        var components = URLComponents()
        components.scheme = issuer.scheme
        components.host = issuer.host
        components.port = issuer.port
        components.path = "/.well-known/oauth-authorization-server\(trimmedPath)"
        return components.url ?? issuer.appendingPathComponent(".well-known/oauth-authorization-server")
    }

    private static func resourceMetadataURL(for resourceURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = resourceURL.scheme
        components.host = resourceURL.host
        components.port = resourceURL.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resourceURL
    }

    private static func isSameOrigin(lhs: URL, rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    private static func isSameIssuer(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedIssuerString(lhs) == normalizedIssuerString(rhs)
    }

    private static func normalizedIssuerString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        var path = components.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path

        if components.port == defaultPort(for: url) {
            components.port = nil
        }

        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func formURLEncoded(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
    }

    private static func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func secureRandomData(length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data(UUID().uuidString.utf8)
    }
}

internal enum MCPSSRFPolicy {
    static func validateTransportURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use http(s)")
        }
        if PrivateIPClassifier.isLocalhostURL(url) {
            return
        }
        guard scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use HTTPS outside localhost")
        }
        try validateHostNotBlocked(url, wrap: { .transportFailure($0) })
    }

    static func validateOAuthURL(_ url: URL, label: String) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw MCPError.authorizationFailed("Expected HTTPS \(label) URL")
        }
        try validateHostNotBlocked(url, wrap: { _ in .authorizationFailed("Expected host in \(label) URL") })
    }

    private static func validateHostNotBlocked(
        _ url: URL,
        wrap: (String) -> MCPError
    ) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw wrap("missing host")
        }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        if PrivateIPClassifier.classifyIPLiteral(normalizedHost) != nil {
            if PrivateIPClassifier.isLocalhostURL(url) == false {
                throw MCPError.ssrfBlocked(url)
            }
        }
    }
}

#if MCPBuiltinCatalog
public enum MCPCatalog {
    public static var all: [MCPServerDescriptor] {
        [notion, linear, github]
    }

    public static var notion: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "5E4A6401-C86D-43DE-847E-AE02A34E89D8")!,
            displayName: "Notion",
            endpointHost: "mcp.notion.com",
            endpointPath: "/v1/sse",
            toolNamespace: "notion",
            oauthScopes: ["read:content", "write:content"],
            oauthIssuerHost: "notion.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Notion."
        )
    }

    public static var linear: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "B146A315-DFA4-4F75-9AF8-7B98CDE569FB")!,
            displayName: "Linear",
            endpointHost: "mcp.linear.app",
            endpointPath: "/v1/sse",
            toolNamespace: "linear",
            oauthScopes: ["read", "write"],
            oauthIssuerHost: "linear.app",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to Linear."
        )
    }

    public static var github: MCPServerDescriptor {
        descriptor(
            id: UUID(uuidString: "7B573A8A-C3CB-450D-9EBE-2E7D4C973682")!,
            displayName: "GitHub",
            endpointHost: "mcp.github.com",
            endpointPath: "/v1/sse",
            toolNamespace: "github",
            oauthScopes: ["read:user", "repo"],
            oauthIssuerHost: "github.com",
            dataDisclosure: "Tool calls may send prompt content and selected arguments to GitHub."
        )
    }

    private static func descriptor(
        id: UUID,
        displayName: String,
        endpointHost: String,
        endpointPath: String,
        toolNamespace: String,
        oauthScopes: [String],
        oauthIssuerHost: String,
        dataDisclosure: String
    ) -> MCPServerDescriptor {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = endpointHost
        endpoint.path = endpointPath

        var issuer = URLComponents()
        issuer.scheme = "https"
        issuer.host = oauthIssuerHost

        var redirect = URLComponents()
        redirect.scheme = "basechat"
        redirect.host = "oauth"
        redirect.path = "/mcp/\(toolNamespace)/callback"

        MCPServerDescriptor(
            id: id,
            displayName: displayName,
            transport: .streamableHTTP(endpoint: endpoint.url!, headers: [:]),
            authorization: .oauth(.init(
                clientName: "BaseChatKit",
                scopes: oauthScopes,
                redirectURI: redirect.url!,
                authorizationServerIssuer: issuer.url!
            )),
            toolNamespace: toolNamespace,
            resourceURL: endpoint.url!,
            dataDisclosure: dataDisclosure
        )
    }
}
#endif
