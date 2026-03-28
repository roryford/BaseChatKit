import SwiftUI
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

    @State private var selectedTab: Tab = .select

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Divider()
                    .accessibilityHidden(true)

                tabContent
            }
            .navigationTitle(selectedTab.rawValue)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Model management section")
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .select:
            ModelSelectTab(onSelect: { dismiss() })
        case .download:
            ModelDownloadTab()
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

    let model: ModelInfo
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Radio button indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        typeBadge(for: model.modelType)

                        if model.modelType != .foundation {
                            Text(model.fileSizeFormatted)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
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
    private func typeBadge(for modelType: ModelType) -> some View {
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
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Download Tab

/// Wraps ModelBrowserView content inline (no nested NavigationStack).
private struct ModelDownloadTab: View {

    @Environment(ModelManagementViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel

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
        .onAppear {
            viewModel.loadRecommendations()
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
        .modelContainer(for: [ChatMessage.self, ChatSession.self, SamplerPreset.self, APIEndpoint.self])
}
