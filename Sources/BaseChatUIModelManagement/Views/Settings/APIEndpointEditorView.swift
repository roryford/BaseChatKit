#if Ollama || CloudSaaS
import SwiftUI
import BaseChatCore
import BaseChatInference

/// Editor for creating or editing an `APIEndpoint`.
///
/// When `endpoint` is `nil`, creates a new endpoint on save.
/// When editing, populates fields from the existing endpoint.
/// Provider selection dynamically updates the base URL and model defaults.
public struct APIEndpointEditorView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    public let endpoint: APIEndpoint? // nil = creating new

    @State private var name: String = ""
    @State private var provider: APIProvider = .openAI
    @State private var baseURL: String = ""
    @State private var modelName: String = ""
    @State private var apiKey: String = ""
    @State private var validationError: String?

    private var isEditing: Bool { endpoint != nil }

    public init(endpoint: APIEndpoint?) {
        self.endpoint = endpoint
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(APIProvider.availableInBuild) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }

                    TextField("Display Name", text: $name)
                }

                Section("Connection") {
                    TextField("Server URL", text: $baseURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    TextField("Model Name", text: $modelName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                if provider.requiresAPIKey {
                    Section("Authentication") {
                        SecureField("API Key", text: $apiKey)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        if isEditing, let account = endpoint?.keychainAccount,
                           let existing = KeychainService.retrieve(account: account), !existing.isEmpty {
                            Text("Current key: \(KeychainService.masked(existing))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !provider.requiresAPIKey {
                    Section {
                        Label {
                            Text("This provider runs locally and doesn't require an API key.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "network")
                                .foregroundStyle(.green)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                if let error = validationError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Endpoint" : "Add Endpoint")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .onAppear { populateFields() }
            .onChange(of: provider) { _, newProvider in
                if !isEditing {
                    baseURL = newProvider.defaultBaseURL
                    modelName = newProvider.defaultModelName
                    if name.isEmpty || APIProvider.availableInBuild.map(\.rawValue).contains(name) {
                        name = newProvider.rawValue
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func populateFields() {
        if let endpoint {
            name = endpoint.name
            provider = endpoint.provider
            baseURL = endpoint.baseURL
            modelName = endpoint.modelName
            // Don't populate apiKey — user must re-enter or leave blank to keep existing
        } else {
            name = provider.rawValue
            baseURL = provider.defaultBaseURL
            modelName = provider.defaultModelName
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModelName = trimmedModelName.isEmpty ? provider.defaultModelName : trimmedModelName

        switch APIEndpointDraftValidator.validate(
            provider: provider,
            baseURL: trimmedURL,
            modelName: resolvedModelName
        ) {
        case .failure(let reason):
            validationError = reason.errorDescription
            return
        case .success:
            break
        }

        validationError = nil
        var createdEndpoint: APIEndpoint?

        if let endpoint {
            // Update existing
            endpoint.name = trimmedName
            endpoint.provider = provider
            endpoint.baseURL = trimmedURL.isEmpty ? provider.defaultBaseURL : trimmedURL
            endpoint.modelName = resolvedModelName

            if !apiKey.isEmpty {
                do {
                    try endpoint.setAPIKey(apiKey)
                } catch {
                    // `KeychainError.localizedDescription` already reads as a
                    // complete sentence (e.g. "Couldn't store the API key in
                    // the Keychain: The device appears to be locked…").
                    validationError = error.localizedDescription
                    return
                }
            }
        } else {
            // Create new
            let newEndpoint = APIEndpoint(
                name: trimmedName,
                provider: provider,
                baseURL: trimmedURL.isEmpty ? nil : trimmedURL,
                modelName: resolvedModelName
            )
            modelContext.insert(newEndpoint)
            createdEndpoint = newEndpoint

            if !apiKey.isEmpty {
                do {
                    try newEndpoint.setAPIKey(apiKey)
                } catch {
                    modelContext.delete(newEndpoint)
                    // `KeychainError.localizedDescription` already reads as a
                    // complete sentence (e.g. "Couldn't store the API key in
                    // the Keychain: The device appears to be locked…").
                    validationError = error.localizedDescription
                    return
                }
            }
        }

        do {
            try modelContext.save()
            dismiss()
        } catch {
            if let createdEndpoint {
                modelContext.delete(createdEndpoint)
            }
            validationError = error.localizedDescription.isEmpty
                ? "Failed to save the endpoint configuration."
                : error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview("Add Endpoint") {
    APIEndpointEditorView(endpoint: nil)
        .modelContainer(for: APIEndpoint.self, inMemory: true)
}
#endif

