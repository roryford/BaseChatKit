import SwiftUI
import BaseChatCore

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
                        ForEach(APIProvider.allCases) { p in
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

                        if isEditing, let existing = endpoint?.apiKey, !existing.isEmpty {
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
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { populateFields() }
            .onChange(of: provider) { _, newProvider in
                if !isEditing {
                    baseURL = newProvider.defaultBaseURL
                    modelName = newProvider.defaultModelName
                    if name.isEmpty || APIProvider.allCases.map(\.rawValue).contains(name) {
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

        if let error = validateURL(trimmedURL) {
            validationError = error
            return
        }

        validationError = nil

        if let endpoint {
            // Update existing
            endpoint.name = trimmedName
            endpoint.provider = provider
            endpoint.baseURL = trimmedURL.isEmpty ? provider.defaultBaseURL : trimmedURL
            endpoint.modelName = modelName

            if !apiKey.isEmpty {
                endpoint.setAPIKey(apiKey)
            }
        } else {
            // Create new
            let newEndpoint = APIEndpoint(
                name: trimmedName,
                provider: provider,
                baseURL: trimmedURL.isEmpty ? nil : trimmedURL,
                modelName: modelName.isEmpty ? nil : modelName
            )
            modelContext.insert(newEndpoint)

            if !apiKey.isEmpty {
                newEndpoint.setAPIKey(apiKey)
            }
        }

        try? modelContext.save()
        dismiss()
    }

    /// Returns an error message if the URL is invalid, or `nil` if it passes validation.
    private func validateURL(_ urlString: String) -> String? {
        // Empty URL is allowed — the provider default will be used
        guard !urlString.isEmpty else { return nil }

        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return "Enter a valid URL (e.g. https://api.example.com)."
        }

        guard scheme == "http" || scheme == "https" else {
            return "URL must use http:// or https://."
        }

        // Allow plain HTTP only for localhost / loopback addresses
        if scheme == "http" {
            let host = url.host?.lowercased() ?? ""
            let isLocal = host == "localhost"
                || host == "127.0.0.1"
                || host == "::1"
                || host.hasSuffix(".local")
            if !isLocal {
                return "Remote servers must use HTTPS. Plain HTTP is only allowed for localhost."
            }
        }

        return nil
    }
}

// MARK: - Preview

#Preview("Add Endpoint") {
    APIEndpointEditorView(endpoint: nil)
        .modelContainer(for: APIEndpoint.self, inMemory: true)
}
