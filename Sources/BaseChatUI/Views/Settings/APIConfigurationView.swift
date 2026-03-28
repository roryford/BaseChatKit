import SwiftUI
import SwiftData
import BaseChatCore

/// Main settings view for managing cloud API endpoints.
///
/// Presented as a sheet from `GenerationSettingsView`. Lists all configured
/// `APIEndpoint` entries with swipe-to-delete, and offers an "Add Endpoint"
/// button that presents `APIEndpointEditorView`.
public struct APIConfigurationView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \APIEndpoint.createdAt, order: .reverse)
    private var endpoints: [APIEndpoint]

    @State private var showAddSheet = false
    @State private var endpointToEdit: APIEndpoint?
    @State private var showDeleteConfirmation = false
    @State private var endpointToDelete: APIEndpoint?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Endpoints") {
                    if endpoints.isEmpty {
                        Text("No cloud APIs configured.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(endpoints) { endpoint in
                        APIEndpointRow(endpoint: endpoint)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                endpointToEdit = endpoint
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    endpointToDelete = endpoint
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }

                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Endpoint", systemImage: "plus.circle")
                    }
                }

                Section {
                    Label {
                        Text("When using cloud APIs, your messages are sent to external servers. Your conversations are no longer on-device only.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.yellow)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Privacy warning: When using cloud APIs, your messages are sent to external servers. Your conversations are no longer on-device only.")
                }
            }
            .navigationTitle("Cloud APIs")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                APIEndpointEditorView(endpoint: nil)
            }
            .sheet(item: $endpointToEdit) { endpoint in
                APIEndpointEditorView(endpoint: endpoint)
            }
            .alert("Delete Endpoint", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { endpointToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let endpoint = endpointToDelete {
                        deleteEndpoint(endpoint)
                    }
                    endpointToDelete = nil
                }
            } message: {
                if let endpoint = endpointToDelete {
                    Text("Delete \"\(endpoint.name)\"? The API key will also be removed.")
                }
            }
        }
    }

    private func deleteEndpoint(_ endpoint: APIEndpoint) {
        endpoint.deleteAPIKey()
        modelContext.delete(endpoint)
        try? modelContext.save()
    }
}

// MARK: - Preview

#Preview("API Configuration") {
    APIConfigurationView()
        .modelContainer(for: APIEndpoint.self, inMemory: true)
}
