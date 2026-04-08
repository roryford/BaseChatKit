import SwiftUI
import BaseChatCore

/// Sheet for manually configuring a remote inference server connection.
///
/// Presented alongside ``ServerDiscoveryView`` to let users enter a server URL,
/// optional API key, and backend type when auto-discovery is unavailable.
///
/// ## Usage
///
/// ```swift
/// .sheet(isPresented: $showRemoteConfig) {
///     RemoteServerConfigSheet { endpoint in
///         // use endpoint
///     }
///     .modelContext(container.mainContext)
/// }
/// ```
public struct RemoteServerConfigSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Called when the user saves the configuration, passing the created endpoint.
    public var onSave: ((APIEndpoint) -> Void)?

    @State private var serverURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var backendType: BackendType = .openAICompatible
    @State private var errorMessage: String?

    public init(onSave: ((APIEndpoint) -> Void)? = nil) {
        self.onSave = onSave
    }

    enum BackendType: String, CaseIterable, Identifiable {
        case openAICompatible = "OpenAI-compatible"
        case ollama = "Ollama"
        case koboldCpp = "KoboldCpp"

        var id: String { rawValue }

        var defaultPort: String {
            switch self {
            case .openAICompatible: return "8080"
            case .ollama: return "11434"
            case .koboldCpp: return "5001"
            }
        }

        var apiProvider: APIProvider {
            switch self {
            case .openAICompatible: return .custom
            case .ollama: return .ollama
            case .koboldCpp: return .koboldCpp
            }
        }

    }

    public var body: some View {
        NavigationStack {
            Form {
                backendTypeSection
                connectionSection
                modelSection
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Remote Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Sections

    private var backendTypeSection: some View {
        Section("Backend Type") {
            Picker("Type", selection: $backendType) {
                ForEach(BackendType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: backendType) { _, newType in
                // Pre-fill default URL when type changes.
                if serverURL.isEmpty {
                    serverURL = "http://localhost:\(newType.defaultPort)"
                }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("Server URL", text: $serverURL, prompt: Text("http://192.168.1.10:\(backendType.defaultPort)"))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled()

            SecureField("API Key (optional)", text: $apiKey)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Connection")
        } footer: {
            Text("API key is only needed for authenticated endpoints (e.g. vLLM with auth). Leave blank for local Ollama and KoboldCpp servers.")
                .font(.caption)
        }
    }

    private var modelSection: some View {
        Section {
            TextField("Model name", text: $modelName, prompt: Text(backendType.apiProvider.defaultModelName))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("Model")
        } footer: {
            Text("For Ollama: use the tag shown by `ollama list` (e.g. `llama3.2:8b`).")
                .font(.caption)
        }
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmed)?.host != nil
    }

    private func save() {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let _ = URL(string: trimmedURL)?.host else {
            errorMessage = "Enter a valid server URL."
            return
        }

        let resolvedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? backendType.apiProvider.defaultModelName

        let endpoint = APIEndpoint(
            name: "\(backendType.rawValue) — \(resolvedModel)",
            provider: backendType.apiProvider,
            baseURL: trimmedURL,
            modelName: resolvedModel
        )
        modelContext.insert(endpoint)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            endpoint.setAPIKey(trimmedKey)
        }

        do {
            try modelContext.save()
            onSave?(endpoint)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? "Failed to save the server configuration."
                : error.localizedDescription
        }
    }
}

// MARK: - Helpers

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#Preview("Remote Server Config") {
    RemoteServerConfigSheet()
        .modelContainer(for: APIEndpoint.self, inMemory: true)
}
