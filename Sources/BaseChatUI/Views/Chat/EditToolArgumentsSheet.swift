import SwiftUI
import BaseChatCore

/// Sheet that lets the user inspect and edit the arguments of a pending
/// tool call before approving execution.
///
/// Shows the tool's JSON schema (when provided) as guidance alongside a
/// free-form JSON editor. The "Run" button is disabled while the text is
/// not well-formed JSON — there is no full JSON Schema validator yet, so
/// we enforce parseability only and leave type-level checks to the tool
/// itself. This is a deliberate minimum-viable gate: a follow-up can add
/// real schema validation without changing the sheet's contract.
struct EditToolArgumentsSheet: View {

    let call: ToolCall
    let definition: ToolDefinition?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var arguments: String
    @State private var validationError: String? = nil
    @Environment(\.dismiss) private var dismiss

    init(
        call: ToolCall,
        definition: ToolDefinition?,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.call = call
        self.definition = definition
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _arguments = State(initialValue: Self.prettyPrint(call.arguments))
    }

    var body: some View {
        #if os(macOS)
        sheetContent
            .frame(minWidth: 480, minHeight: 420)
        #else
        NavigationStack {
            sheetContent
        }
        #endif
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let definition {
                schemaSection(for: definition)
            }

            Text("Arguments")
                .font(.callout.bold())

            argumentsEditor

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding()
        .onChange(of: arguments) { _, newValue in
            validationError = Self.validationMessage(for: newValue)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review tool call")
                .font(.title3.bold())
            Text(call.name)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            if let description = definition?.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func schemaSection(for definition: ToolDefinition) -> some View {
        DisclosureGroup("Schema") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(definition.inputSchema.properties.keys.sorted(), id: \.self) { key in
                    if let prop = definition.inputSchema.properties[key] {
                        schemaRow(key: key, property: prop, required: definition.inputSchema.required.contains(key))
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func schemaRow(key: String, property: ToolParameterProperty, required: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.caption.monospaced().bold())
            Text("(\(property.type)\(required ? ", required" : ""))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(property.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var argumentsEditor: some View {
        TextEditor(text: $arguments)
            .font(.callout.monospaced())
            .frame(minHeight: 120)
            .padding(6)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Tool arguments JSON")
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Run") {
                onSubmit(arguments)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(validationError != nil)
        }
    }

    // MARK: - Helpers

    /// Pretty-prints JSON when possible, otherwise returns the raw string so
    /// the user still sees something editable.
    static func prettyPrint(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: pretty, encoding: .utf8) else {
            return raw
        }
        return string
    }

    /// Returns a human-readable error when the arguments are not parseable JSON,
    /// or `nil` when they are valid. Empty strings are treated as `{}` — most
    /// tool schemas default missing keys to required, which the tool itself
    /// surfaces as an error if they aren't provided.
    static func validationMessage(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let data = trimmed.data(using: .utf8) else {
            return "Arguments are not valid UTF-8."
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return nil
        } catch {
            return "Arguments are not valid JSON."
        }
    }
}

#Preview {
    EditToolArgumentsSheet(
        call: ToolCall(id: "call_1", name: "send_email", arguments: "{\"to\":\"user@example.com\",\"subject\":\"Hi\"}"),
        definition: ToolDefinition(
            name: "send_email",
            description: "Send an email to a given address.",
            inputSchema: ToolInputSchema(
                properties: [
                    "to": ToolParameterProperty(type: "string", description: "Destination address"),
                    "subject": ToolParameterProperty(type: "string", description: "Subject line")
                ],
                required: ["to"]
            )
        ),
        onSubmit: { _ in },
        onCancel: { }
    )
}
