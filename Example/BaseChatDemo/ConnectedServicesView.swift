import SwiftUI
import BaseChatInference

#if canImport(BaseChatMCP)
import BaseChatMCP
import Observation

struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: ConnectedServicesCoordinator
    @State private var pendingConnect: MCPServerDescriptor?

    init(toolRegistry: ToolRegistry) {
        _coordinator = State(initialValue: ConnectedServicesCoordinator(toolRegistry: toolRegistry))
    }

    var body: some View {
        NavigationStack {
            List {
                if coordinator.catalog.isEmpty {
                    Section("Connected Services") {
                        Label(
                            coordinator.catalogHelpText,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connected-services-catalog-empty-message")
                    }
                } else {
                    Section("Connected Services") {
                        ForEach(coordinator.catalog, id: \.id) { descriptor in
                            serviceRow(for: descriptor)
                        }
                    }
                }
            }
            .navigationTitle("Connected Services")
            .accessibilityIdentifier("connected-services-sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                coordinator.startListenersIfNeeded()
            }
            .confirmationDialog(
                "Connect service",
                isPresented: Binding(
                    get: { pendingConnect != nil },
                    set: { if !$0 { pendingConnect = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let descriptor = pendingConnect {
                    Button("Connect") {
                        coordinator.connect(descriptor)
                        pendingConnect = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingConnect = nil
                }
            } message: {
                if let descriptor = pendingConnect {
                    Text(disclosureMessage(for: descriptor))
                }
            }
        }
    }

    @ViewBuilder
    private func serviceRow(for descriptor: MCPServerDescriptor) -> some View {
        let snapshot = coordinator.snapshot(for: descriptor.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.displayName)
                        .font(.headline)
                    Text(snapshot.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("connected-service-status-\(descriptor.id.uuidString)")
                }

                Spacer()

                if snapshot.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }

                if snapshot.isConnected {
                    Button("Disconnect", role: .destructive) {
                        coordinator.disconnect(descriptor.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("connected-service-disconnect-\(descriptor.id.uuidString)")
                } else {
                    Button("Connect") {
                        pendingConnect = descriptor
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot.isBusy)
                    .accessibilityIdentifier("connected-service-connect-\(descriptor.id.uuidString)")
                }
            }

            if let auth = snapshot.authorizationRequest {
                Label("Authorization required", systemImage: "person.badge.key")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if auth.requiredScopes.isEmpty == false {
                    Text("Scopes: \(auth.requiredScopes.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = snapshot.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            DisclosureGroup("Data use") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(descriptor.dataDisclosure)
                        .font(.caption)
                    Text("Approval policy: \(approvalLabel(descriptor.approvalPolicy))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("connected-service-row-\(descriptor.id.uuidString)")
    }

    private func approvalLabel(_ policy: MCPApprovalPolicy) -> String {
        switch policy {
        case .perCall: return "Per call"
        case .perTurn: return "Per turn"
        case .sessionForTool: return "Session per tool"
        case .sessionForServer: return "Session per server"
        case .persistentForTool: return "Persistent per tool"
        }
    }

    private func disclosureMessage(for descriptor: MCPServerDescriptor) -> String {
        let scopes: String = {
            guard case .oauth(let oauth) = descriptor.authorization else { return "" }
            guard oauth.scopes.isEmpty == false else { return "" }
            return "\n\nRequested scopes: \(oauth.scopes.joined(separator: ", "))."
        }()
        return "\(descriptor.dataDisclosure)\(scopes)"
    }
}

@MainActor
@Observable
final class ConnectedServicesCoordinator {
    private let toolRegistry: ToolRegistry
    private let client: MCPClient
    private var sourcesByID: [UUID: MCPToolSource] = [:]
    private var snapshotsByID: [UUID: ConnectedServiceSnapshot] = [:]
    private var eventsTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    let catalog: [MCPServerDescriptor]
    let catalogHelpText: String

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
        self.client = MCPClient()

        #if MCPBuiltinCatalog
        self.catalog = MCPCatalog.all
        self.catalogHelpText = "No built-in entries available."
        #else
        self.catalog = ConnectedServicesFallbackCatalog.all
        self.catalogHelpText = "Using fallback demo catalog. Enable the MCPBuiltinCatalog trait to use BaseChatMCP built-ins."
        #endif

        for descriptor in catalog {
            snapshotsByID[descriptor.id] = .init()
        }
    }

    func startListenersIfNeeded() {
        guard eventsTask == nil, stateTask == nil else { return }

        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in client.connectionEvents {
                await self.handle(event)
            }
        }

        stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in client.connectionState {
                await self.handle(state)
            }
        }
    }

    func snapshot(for serverID: UUID) -> ConnectedServiceSnapshot {
        snapshotsByID[serverID] ?? .init()
    }

    func connect(_ descriptor: MCPServerDescriptor) {
        guard sourcesByID[descriptor.id] == nil else { return }
        markBusy(true, serverID: descriptor.id)
        setState(.connecting, serverID: descriptor.id)

        Task {
            do {
                let source = try await client.connect(descriptor)
                await source.register(in: toolRegistry)
                let count = await source.currentToolNames().count
                await MainActor.run {
                    self.sourcesByID[descriptor.id] = source
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = true
                        snapshot.state = .ready
                        snapshot.toolCount = count
                        snapshot.errorMessage = nil
                        snapshot.authorizationRequest = nil
                    }
                }
            } catch let mcpError as MCPError {
                await MainActor.run {
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = false
                        snapshot.state = .failed
                        snapshot.errorMessage = Self.errorMessage(for: mcpError)
                        if case .authorizationRequired(let request) = mcpError {
                            snapshot.authorizationRequest = request
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateSnapshot(descriptor.id) { snapshot in
                        snapshot.isBusy = false
                        snapshot.isConnected = false
                        snapshot.state = .failed
                        snapshot.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func disconnect(_ serverID: UUID) {
        guard let source = sourcesByID[serverID] else { return }
        markBusy(true, serverID: serverID)

        Task {
            await source.unregister(from: toolRegistry)
            await client.disconnect(serverID: serverID)
            await MainActor.run {
                self.sourcesByID.removeValue(forKey: serverID)
                self.updateSnapshot(serverID) { snapshot in
                    snapshot.isBusy = false
                    snapshot.isConnected = false
                    snapshot.state = .idle
                    snapshot.toolCount = 0
                    snapshot.errorMessage = nil
                    snapshot.authorizationRequest = nil
                }
            }
        }
    }

    private func handle(_ event: MCPConnectionEvent) async {
        switch event {
        case .connecting(let serverID):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .connecting
            }
        case .connected(let serverID, _):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .ready
                snapshot.isConnected = true
                snapshot.errorMessage = nil
                snapshot.authorizationRequest = nil
            }
            await refreshToolCount(for: serverID)
        case .toolsChanged(let serverID, _, _):
            await refreshToolCount(for: serverID)
        case .authorizationRequired(let serverID, let request):
            updateSnapshot(serverID) { snapshot in
                snapshot.authorizationRequest = request
                snapshot.errorMessage = "Authorization required before this service can be used."
                snapshot.state = .failed
                snapshot.isBusy = false
            }
        case .scopeDowngraded(let serverID, let requested, let granted):
            updateSnapshot(serverID) { snapshot in
                snapshot.errorMessage = "Granted scopes: \(granted.joined(separator: ", ")) (requested: \(requested.joined(separator: ", ")))."
            }
        case .disconnected(let serverID, _):
            sourcesByID.removeValue(forKey: serverID)
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .idle
                snapshot.isConnected = false
                snapshot.isBusy = false
                snapshot.toolCount = 0
            }
        case .error(let serverID, let error):
            updateSnapshot(serverID) { snapshot in
                snapshot.state = .failed
                snapshot.isBusy = false
                snapshot.errorMessage = Self.errorMessage(for: error)
                if case .authorizationRequired(let request) = error {
                    snapshot.authorizationRequest = request
                }
            }
        }
    }

    private func handle(_ state: MCPConnectionState) async {
        if state == .idle {
            for serverID in snapshotsByID.keys where sourcesByID[serverID] == nil {
                updateSnapshot(serverID) { snapshot in
                    if snapshot.isBusy == false {
                        snapshot.state = .idle
                    }
                }
            }
        }
    }

    private func refreshToolCount(for serverID: UUID) async {
        guard let source = sourcesByID[serverID] else { return }
        let toolCount = await source.currentToolNames().count
        await MainActor.run {
            self.updateSnapshot(serverID) { snapshot in
                snapshot.toolCount = toolCount
                snapshot.isConnected = true
            }
        }
    }

    private func setState(_ state: MCPConnectionState, serverID: UUID) {
        updateSnapshot(serverID) { snapshot in
            snapshot.state = state
        }
    }

    private func markBusy(_ value: Bool, serverID: UUID) {
        updateSnapshot(serverID) { snapshot in
            snapshot.isBusy = value
        }
    }

    private func updateSnapshot(_ serverID: UUID, transform: (inout ConnectedServiceSnapshot) -> Void) {
        var snapshot = snapshotsByID[serverID] ?? .init()
        transform(&snapshot)
        snapshotsByID[serverID] = snapshot
    }

    private static func errorMessage(for error: MCPError) -> String {
        switch error {
        case .authorizationRequired:
            return "Authorization required before this service can be used."
        case .requestTimeout:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
        case .unauthorized:
            return "Unauthorized."
        case .failed(let message), .transportFailure(let message), .authorizationFailed(let message):
            return message
        default:
            return String(describing: error)
        }
    }
}

struct ConnectedServiceSnapshot {
    var state: MCPConnectionState = .idle
    var isConnected = false
    var isBusy = false
    var toolCount = 0
    var errorMessage: String?
    var authorizationRequest: MCPAuthorizationRequest?

    var statusText: String {
        let stateText: String = {
            switch state {
            case .idle: return "Idle"
            case .connecting: return "Connecting"
            case .ready: return "Connected"
            case .reconnecting: return "Reconnecting"
            case .failed: return "Failed"
            }
        }()
        if isConnected {
            return "\(stateText) · \(toolCount) tools"
        }
        return stateText
    }
}

private enum ConnectedServicesFallbackCatalog {
    static let all: [MCPServerDescriptor] = [notion, linear, github]

    private static var notion: MCPServerDescriptor {
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

    private static var linear: MCPServerDescriptor {
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

    private static var github: MCPServerDescriptor {
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

        return MCPServerDescriptor(
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

#else

struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss

    let toolRegistry: ToolRegistry

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Connected Services") {
                    Label("BaseChatMCP is not linked in this build.", systemImage: "link.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connected Services")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#endif
