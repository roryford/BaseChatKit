import SwiftUI
import UniformTypeIdentifiers
import BaseChatCore

/// Inline HuggingFace browser content used by `ModelManagementSheet`.
struct HuggingFaceBrowserView: View {

    @Environment(ModelManagementViewModel.self) private var viewModel
    @Environment(ChatViewModel.self) private var chatViewModel

    let recommendedModelIDs: Set<String>?
    let recommendationTitle: String?
    let recommendationMessage: String?

    @State private var showImporter = false
    @State private var importSuccessMessage: String?
    @State private var importErrorMessage: String?

    private static var importContentTypes: [UTType] {
        let gguf = UTType(filenameExtension: "gguf") ?? .data
        return [gguf, .folder]
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search HuggingFace models...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.webSearch)
                        .submitLabel(.search)
                        #endif
                        .onSubmit {
                            Task { await viewModel.search() }
                        }
                        .accessibilityLabel("Search HuggingFace models")
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }

                Button {
                    importSuccessMessage = nil
                    importErrorMessage = nil
                    showImporter = true
                } label: {
                    Label("Import Local Model", systemImage: "plus.circle")
                }
                .accessibilityLabel("Import local model")
            }

            WhyDownloadView()

            if let message = importSuccessMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(message)
                }
            }

            if let recommendationTitle, let recommendationMessage {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(recommendationTitle)
                            .font(.headline)

                        Text(recommendationMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

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

            if !viewModel.searchResults.isEmpty {
                let groups = DownloadableModelGroup.group(viewModel.searchResults)
                Section("Search Results") {
                    ForEach(groups) { group in
                        if group.variants.count == 1 {
                            DownloadableModelRow(model: group.variants[0])
                        } else {
                            DisclosureGroup {
                                ForEach(group.variants) { variant in
                                    DownloadableModelRow(model: variant)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.displayName)
                                        .font(.headline)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text("\(group.variants.count) variants")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let sizeRange = group.sizeRange {
                                            Text(sizeRange)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if let error = importErrorMessage ?? viewModel.searchError {
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

                    if viewModel.searchError != nil {
                        Button("Retry") {
                            Task { await viewModel.search() }
                        }
                    }
                }
            }
        }
        .onChange(of: viewModel.completedDownloadCount) {
            viewModel.invalidateModelCache()
            chatViewModel.refreshModels()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: Self.importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .onAppear {
            viewModel.loadRecommendations(preferredModelIDs: recommendedModelIDs)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let imported = try viewModel.importModel(from: url)
                chatViewModel.refreshModels()
                importErrorMessage = nil
                importSuccessMessage = "Imported \(imported.name). Open Select to use it."
            } catch {
                importSuccessMessage = nil
                importErrorMessage = error.localizedDescription
            }

        case .failure(let error):
            importSuccessMessage = nil
            importErrorMessage = error.localizedDescription
        }
    }
}
