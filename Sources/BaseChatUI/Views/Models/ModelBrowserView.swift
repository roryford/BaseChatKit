import SwiftUI
import BaseChatCore

/// Sheet for browsing and downloading models from HuggingFace.
///
/// Shows curated recommendations for this device and supports search
/// for additional models. Downloads are handled by the background download
/// manager and progress appears inline.
public struct ModelBrowserView: View {

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            List {
                WhyDownloadView()

                Section("Recommended for Your Device") {
                    if viewModel.recommendedModels.isEmpty {
                        Text("No recommendations available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.recommendedModels) { model in
                            DownloadableModelRow(model: model)
                        }
                    }
                }

                if !viewModel.searchResults.isEmpty {
                    Section("Search Results") {
                        ForEach(viewModel.searchResults) { model in
                            DownloadableModelRow(model: model)
                        }
                    }
                }

                if viewModel.isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView("Searching...")
                                .accessibilityLabel("Searching for models")
                            Spacer()
                        }
                    }
                }

                if let error = viewModel.searchError {
                    Section {
                        Label {
                            Text(error)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Search error: \(error)")
                    }
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search HuggingFace models...")
            .onSubmit(of: .search) {
                Task { await viewModel.search() }
            }
            .navigationTitle("Browse Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                viewModel.loadRecommendations()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ModelBrowserView()
        .environment(ModelManagementViewModel())
}
