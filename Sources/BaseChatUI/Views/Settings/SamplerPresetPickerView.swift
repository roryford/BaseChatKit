import SwiftUI
import SwiftData
import BaseChatCore

/// Picker and management UI for sampler presets within GenerationSettingsView.
public struct SamplerPresetPickerView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \SamplerPreset.createdAt, order: .reverse)
    private var presets: [SamplerPreset]

    @State private var showSaveAlert = false
    @State private var newPresetName = ""
    @State private var showDeleteConfirmation = false
    @State private var presetToDelete: SamplerPreset?

    public init() {}

    public var body: some View {
        Section("Sampler Presets") {
            if !presets.isEmpty {
                ForEach(presets) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text("T:\(String(format: "%.1f", preset.temperature)) P:\(String(format: "%.2f", preset.topP)) R:\(String(format: "%.2f", preset.repeatPenalty))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Apply") {
                            applyPreset(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Apply \(preset.name)")
                        .accessibilityHint("Sets temperature, top P, and repeat penalty from this preset")
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            presetToDelete = preset
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                newPresetName = ""
                showSaveAlert = true
            } label: {
                Label("Save Current as Preset", systemImage: "plus.circle")
            }
        }
        .alert("Save Preset", isPresented: $showSaveAlert) {
            TextField("Preset name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveCurrentAsPreset()
            }
            .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for this sampler preset.")
        }
        .alert("Delete Preset", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { presetToDelete = nil }
            Button("Delete", role: .destructive) {
                if let preset = presetToDelete {
                    deletePreset(preset)
                }
                presetToDelete = nil
            }
        } message: {
            if let preset = presetToDelete {
                Text("Delete \"\(preset.name)\"?")
            }
        }
    }

    private func applyPreset(_ preset: SamplerPreset) {
        viewModel.temperature = preset.temperature
        viewModel.topP = preset.topP
        viewModel.repeatPenalty = preset.repeatPenalty
    }

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let preset = SamplerPreset(
            name: name,
            temperature: viewModel.temperature,
            topP: viewModel.topP,
            repeatPenalty: viewModel.repeatPenalty
        )
        modelContext.insert(preset)

        do {
            try modelContext.save()
        } catch {
            Log.persistence.error("Failed to save preset: \(error)")
        }
    }

    private func deletePreset(_ preset: SamplerPreset) {
        modelContext.delete(preset)
        do {
            try modelContext.save()
        } catch {
            Log.persistence.error("Failed to delete preset: \(error)")
        }
    }
}
