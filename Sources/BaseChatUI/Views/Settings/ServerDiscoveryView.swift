import SwiftUI
import BaseChatCore

/// Sheet for discovering and connecting to local inference servers.
///
/// Presented from `APIConfigurationView` when `showServerDiscovery` is enabled.
/// Shows discovered servers with their available models, and allows manual
/// host:port entry for servers not found by scanning.
public struct ServerDiscoveryView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ServerDiscoveryViewModel.self) private var viewModel

    /// Called when the user connects to a server, passing the created endpoint.
    public var onConnect: ((APIEndpoint) -> Void)?

    public init(onConnect: ((APIEndpoint) -> Void)? = nil) {
        self.onConnect = onConnect
    }

    public var body: some View {
        NavigationStack {
            Form {
                discoveredServersSection

                manualEntrySection

                if let error = viewModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Discover Servers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { viewModel.startDiscovery() }
            .onDisappear { viewModel.stopDiscovery() }
        }
    }

    // MARK: - Discovered Servers

    private var discoveredServersSection: some View {
        Section {
            if viewModel.discoveredServers.isEmpty {
                if viewModel.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning local network...")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No servers found.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(viewModel.discoveredServers) { server in
                serverRow(server)
            }
        } header: {
            HStack {
                Text("Local Servers")
                Spacer()
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private func serverRow(_ server: DiscoveredServer) -> some View {
        let header = HStack(spacing: 8) {
            Image(systemName: serverIcon(for: server.serverType))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.body)
                Text("\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(server.models.count) model\(server.models.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }

        Section {
            header

            if server.models.isEmpty {
                Text("No models available")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            ForEach(Array(server.models.enumerated()), id: \.offset) { _, model in
                Button {
                    connectToModel(server: server, model: model)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body)
                            if let size = model.sizeBytes {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Manual Entry

    private var manualEntrySection: some View {
        ManualEntrySection(viewModel: viewModel)
    }

    // MARK: - Helpers

    private func connectToModel(server: DiscoveredServer, model: RemoteModelInfo) {
        let endpoint = viewModel.createEndpoint(
            server: server,
            model: model,
            modelContext: modelContext
        )
        onConnect?(endpoint)
        dismiss()
    }

    private func serverIcon(for type: ServerType) -> String {
        switch type {
        case .ollama: return "server.rack"
        case .koboldCpp: return "desktopcomputer"
        case .lmStudio: return "display"
        case .openAICompatible: return "cloud"
        }
    }
}

// MARK: - Manual Entry (extracted for @Bindable isolation)

private struct ManualEntrySection: View {
    @Bindable var viewModel: ServerDiscoveryViewModel

    var body: some View {
        Section("Manual Connection") {
            TextField("Hostname or IP", text: $viewModel.manualHost)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

            TextField("Port (default: 11434)", text: $viewModel.manualPort)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif

            Button {
                Task { await viewModel.probeManualEntry() }
            } label: {
                Label("Connect", systemImage: "link")
            }
            .disabled(viewModel.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
