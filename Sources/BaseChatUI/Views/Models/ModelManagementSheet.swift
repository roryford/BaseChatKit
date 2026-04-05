import SwiftUI
import UniformTypeIdentifiers
import BaseChatCore

/// Unified model management sheet combining model selection, download, and storage.
///
/// Replaces the separate model picker, model browser, and storage management entry
/// points with a single tabbed interface. Selecting a model in the "Select" tab
/// immediately activates it and dismisses the sheet.
public struct ModelManagementSheet: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel
    @Environment(\.dismiss) private var dismiss

    private var features: BaseChatConfiguration.Features { BaseChatConfiguration.shared.features }
    private let initialTab: Tab
    private let recommendedModelIDs: Set<String>?
    private let recommendationTitle: String?
    private let recommendationMessage: String?

    public enum Tab: String, CaseIterable {
        case select = "Select"
        case download = "Download"
        case storage = "Storage"

        var systemImage: String {
            switch self {
            case .select: "checkmark.circle"
            case .download: "square.and.arrow.down"
            case .storage: "externaldrive"
            }
        }
    }

    /// The tabs available based on feature flags.
    private var availableTabs: [Tab] {
        var tabs: [Tab] = [.select]
        if features.showModelDownload { tabs.append(.download) }
        if features.showStorageTab { tabs.append(.storage) }
        return tabs
    }

    @State private var selectedTab: Tab

    public init(
        initialTab: Tab = .select,
        recommendedModelIDs: Set<String>? = nil,
        recommendationTitle: String? = nil,
        recommendationMessage: String? = nil
    ) {
        self.initialTab = initialTab
        self.recommendedModelIDs = recommendedModelIDs
        self.recommendationTitle = recommendationTitle
        self.recommendationMessage = recommendationMessage
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        NavigationStack {
            #if os(macOS)
            // On macOS, VStack works correctly and avoids the safeAreaInset
            // state propagation bug where tab content doesn't update on selection.
            VStack(spacing: 0) {
                tabPickerBar
                tabContent
            }
            .navigationTitle(selectedTab.rawValue)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            // On iOS/iPadOS, safeAreaInset is required so the List is a direct
            // child of NavigationStack — a VStack wrapper breaks hit testing on iPad.
            tabContent
                .safeAreaInset(edge: .top, spacing: 0) { tabPickerBar }
                .navigationBarTitleDisplayMode(.inline)
                .navigationTitle(selectedTab.rawValue)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            #endif
        }
        .presentationDetents([.large])
        .onAppear {
            if !availableTabs.contains(selectedTab) {
                selectedTab = .select
            } else if selectedTab != initialTab {
                selectedTab = initialTab
            }
            chatViewModel.refreshModels()
            managementViewModel.invalidateModelCache()
        }
    }

    private var tabPickerBar: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()
                .accessibilityHidden(true)
        }
        .background(.bar)
    }

    // MARK: - Tab Picker

    @ViewBuilder
    private var tabPicker: some View {
        let tabs = availableTabs
        if tabs.count > 1 {
            Picker("Section", selection: $selectedTab) {
                ForEach(tabs, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Model management section")
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .select:
            ModelSelectTab(onSelect: { dismiss() })
        case .download:
            ModelDownloadTab(
                recommendedModelIDs: recommendedModelIDs,
                recommendationTitle: recommendationTitle,
                recommendationMessage: recommendationMessage
            )
        case .storage:
            ModelStorageTab()
        }
    }
}

// MARK: - Select Tab

/// Lists all locally available models with a radio-button style selection.
private struct ModelSelectTab: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    let onSelect: () -> Void

    var body: some View {
        List {
            if chatViewModel.availableModels.isEmpty {
                ContentUnavailableView(
                    "No Models Available",
                    systemImage: "cpu",
                    description: Text("Download a model from the Download tab to get started.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(chatViewModel.availableModels) { model in
                        ModelSelectRow(
                            model: model,
                            isSelected: chatViewModel.selectedModel?.id == model.id
                        ) {
                            chatViewModel.selectedModel = model
                            onSelect()
                        }
                    }
                } footer: {
                    Text("Selecting a model loads it into memory and clears any active cloud API endpoint.")
                        .font(.caption)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .accessibilityLabel("Available models")
    }
}

/// A single row in the model selection list.
private struct ModelSelectRow: View {

    @Environment(ChatViewModel.self) private var chatViewModel

    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void

    /// Compatibility result for this model's type, checked once on render.
    private var compatibilityResult: ModelCompatibilityResult {
        chatViewModel.inferenceService.compatibility(for: model.modelType)
    }

    private var isCompatible: Bool { compatibilityResult.isSupported }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Radio button indicator — grayed out when the backend is unavailable.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        isCompatible
                        ? (isSelected ? Color.accentColor : .secondary)
                        : Color.secondary.opacity(0.4)
                    )
                    .imageScale(.large)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.body)
                        .foregroundStyle(isCompatible ? .primary : .secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        typeBadge(for: model.modelType, isCompatible: isCompatible)

                        if model.modelType != .foundation {
                            Text(model.fileSizeFormatted)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Show why this model's backend is unavailable.
                    if let reason = compatibilityResult.unavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCompatible)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isCompatible ? "" : (compatibilityResult.unavailableReason ?? "Backend not available"))
    }

    private var accessibilityLabel: String {
        let type: String
        switch model.modelType {
        case .gguf: type = "GGUF"
        case .mlx: type = "MLX"
        case .foundation: type = "Apple Foundation Model"
        }
        if model.modelType == .foundation {
            return "\(model.name), \(type)"
        }
        return "\(model.name), \(type), \(model.fileSizeFormatted)"
    }

    @ViewBuilder
    private func typeBadge(for modelType: ModelType, isCompatible: Bool) -> some View {
        let (label, color): (String, Color) = {
            switch modelType {
            case .gguf: return ("GGUF", .orange)
            case .mlx: return ("MLX", .purple)
            case .foundation: return ("Foundation", .blue)
            }
        }()

        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(isCompatible ? color : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (isCompatible ? color : Color.secondary).opacity(0.12),
                in: Capsule()
            )
    }
}

// MARK: - Download Tab

/// Wraps ModelBrowserView content inline (no nested NavigationStack).
private struct ModelDownloadTab: View {

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

// MARK: - Storage Tab

/// Wraps StorageManagementView content inline (no nested NavigationStack).
private struct ModelStorageTab: View {

    @Environment(ChatViewModel.self) private var chatViewModel
    @Environment(ModelManagementViewModel.self) private var managementViewModel

    @State private var modelToDelete: ModelInfo?
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            storageOverviewSection
            downloadedModelsSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .alert(
            "Delete Model",
            isPresented: $showDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button("Delete", role: .destructive) {
                deleteModel(model)
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { model in
            Text("Are you sure you want to delete \"\(model.name)\"? This will free \(model.fileSizeFormatted) of storage. This action cannot be undone.")
        }
    }

    private var storageOverviewSection: some View {
        Section("Storage Overview") {
            HStack {
                Label("Total Used", systemImage: "externaldrive.fill")
                Spacer()
                Text(managementViewModel.totalStorageUsed)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Models Directory")
                    .font(.subheadline)

                #if os(macOS)
                Button {
                    openModelsDirectoryInFinder()
                } label: {
                    Text(managementViewModel.modelsDirectoryPath)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open models directory in Finder")
                #else
                Text(managementViewModel.modelsDirectoryPath)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                #endif
            }
        }
    }

    private var downloadedModelsSection: some View {
        Section("Downloaded Models") {
            let models = chatViewModel.availableModels.filter { $0.modelType != .foundation }

            if models.isEmpty {
                Text("No downloaded models.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.body)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                Text(model.backendLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.fileSizeFormatted)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Button {
                            modelToDelete = model
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(model.name)")
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.name), \(model.backendLabel), \(model.fileSizeFormatted)")
                }
            }
        }
    }

    private func deleteModel(_ model: ModelInfo) {
        do {
            try managementViewModel.deleteModel(model)
            chatViewModel.refreshModels()
        } catch {
            Log.download.error("Failed to delete model: \(error)")
        }
        modelToDelete = nil
    }

    #if os(macOS)
    private func openModelsDirectoryInFinder() {
        let url = URL(fileURLWithPath: managementViewModel.modelsDirectoryPath)
        NSWorkspace.shared.open(url)
    }
    #endif
}

// MARK: - Preview

#Preview {
    ModelManagementSheet()
        .environment(ChatViewModel())
        .environment(ModelManagementViewModel())
        .modelContainer(try! ModelContainerFactory.makeInMemoryContainer())
}
