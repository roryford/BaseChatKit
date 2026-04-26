import SwiftUI
import BaseChatInference

#if canImport(BaseChatMCP)
import BaseChatMCP
import Observation

struct ConnectedServicesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: DemoMCPCoordinator
    @State private var pendingConnect: MCPServerDescriptor?

    init(toolRegistry: ToolRegistry) {
        _coordinator = State(initialValue: DemoMCPCoordinator(toolRegistry: toolRegistry))
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
