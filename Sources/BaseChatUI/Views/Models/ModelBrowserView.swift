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
                Section {
                    ModelBrowserSearchField(text: $viewModel.searchQuery)
                }

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
            .onSubmit(of: .search) {
                Task { await viewModel.search() }
            }
            .onChange(of: viewModel.searchQuery) { _, _ in
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

private struct ModelBrowserSearchField: View {

    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            searchTextField

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var searchTextField: some View {
        #if os(iOS)
        TextField("Search HuggingFace models...", text: $text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .submitLabel(.search)
        #else
        TextField("Search HuggingFace models...", text: $text)
        #endif
    }
}

// MARK: - Preview

#Preview {
    ModelBrowserView()
        .environment(ModelManagementViewModel())
}
