import BaseChatInference

#if canImport(BaseChatMCP)
import BaseChatMCP
import Observation

// Coordinator for ConnectedServicesView. Owns the MCPClient, drives connect/disconnect
// lifecycle, and projects raw MCPConnectionEvent/MCPConnectionState into snapshots the
// view can observe without holding any MCP types directly.
@MainActor
@Observable
final class DemoMCPCoordinator {
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
        self.catalog = []
        self.catalogHelpText = "Enable the MCPBuiltinCatalog trait or provide custom server descriptors."
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

#endif
