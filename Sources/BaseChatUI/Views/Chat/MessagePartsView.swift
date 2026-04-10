import SwiftUI
import BaseChatCore

/// Renders an array of ``MessagePart`` values within a message bubble.
///
/// Text parts are rendered inline (markdown for assistant, plain for user),
/// images are shown as thumbnails, and tool calls/results are displayed as
/// labeled disclosure groups.
///
/// When the optional ``approvalCoordinator`` is provided and a tool call
/// has state ``ToolCallApprovalState/pending``, the bubble renders Approve /
/// Reject / Edit controls that route back through the coordinator. Without
/// the coordinator the view is strictly read-only, matching the legacy
/// behaviour used by snapshot tests and preview contexts.
struct MessagePartsView: View {
    let parts: [MessagePart]
    let role: MessageRole
    var approvalCoordinator: ToolCallApprovalCoordinator? = nil

    @State private var editingCall: ToolCall? = nil
    @State private var editingDefinition: ToolDefinition? = nil

    var body: some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            partView(for: part)
        }
        .sheet(item: $editingCall) { call in
            EditToolArgumentsSheet(
                call: call,
                definition: editingDefinition,
                onSubmit: { newArguments in
                    approvalCoordinator?.resolve(
                        id: call.id,
                        with: .approved(arguments: newArguments)
                    )
                    editingCall = nil
                    editingDefinition = nil
                },
                onCancel: {
                    editingCall = nil
                    editingDefinition = nil
                }
            )
        }
    }

    @ViewBuilder
    private func partView(for part: MessagePart) -> some View {
        switch part {
        case .text(let text):
            textView(text)

        case .image(let data, _):
            imageView(data)

        case .toolCall(let id, let name, let arguments, let state):
            toolCallView(id: id, name: name, arguments: arguments, state: state)

        case .toolResult(let id, let content):
            toolResultView(id: id, content: content)
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if role == .assistant {
            AssistantMarkdownView(content: text)
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(role == .user ? .white : .primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        #if os(iOS)
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        #endif
    }

    private func toolCallView(
        id: String,
        name: String,
        arguments: String,
        state: ToolCallApprovalState
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup {
                Text(arguments)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    Label(name, systemImage: icon(for: state))
                        .font(.callout.bold())
                        .foregroundStyle(foregroundStyle(for: state))
                    Spacer()
                    statusBadge(for: state)
                }
            }

            if state == .pending && approvalCoordinator != nil {
                approvalControls(id: id, name: name, arguments: arguments)
            }
        }
        .padding(8)
        .background(backgroundStyle(for: state), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: state, name: name))
    }

    @ViewBuilder
    private func approvalControls(id: String, name: String, arguments: String) -> some View {
        HStack(spacing: 8) {
            Button {
                approvalCoordinator?.resolve(id: id, with: .approved(arguments: arguments))
            } label: {
                Label("Approve", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)

            Button {
                let call = ToolCall(id: id, name: name, arguments: arguments)
                editingDefinition = approvalCoordinator?
                    .pendingApprovals
                    .first(where: { $0.id == id })?
                    .definition
                editingCall = call
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                approvalCoordinator?.resolve(id: id, with: .rejected(reason: "User rejected tool call"))
            } label: {
                Label("Reject", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func toolResultView(id: String, content: String) -> some View {
        DisclosureGroup {
            Text(content)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tool Result", systemImage: "arrow.turn.down.left")
                .font(.callout.bold())
        }
        .padding(8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Styling helpers

    private func icon(for state: ToolCallApprovalState) -> String {
        switch state {
        case .pending:  return "clock"
        case .approved: return "wrench"
        case .edited:   return "wrench.adjustable"
        case .rejected: return "nosign"
        }
    }

    @ViewBuilder
    private func statusBadge(for state: ToolCallApprovalState) -> some View {
        switch state {
        case .pending:
            Text("Pending approval")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        case .edited:
            Text("Edited")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.2), in: Capsule())
                .foregroundStyle(.blue)
        case .rejected:
            Text("Rejected")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.2), in: Capsule())
                .foregroundStyle(.red)
        case .approved:
            EmptyView()
        }
    }

    private func foregroundStyle(for state: ToolCallApprovalState) -> Color {
        switch state {
        case .pending:  return .orange
        case .rejected: return .red
        case .edited:   return .blue
        case .approved: return .primary
        }
    }

    private func backgroundStyle(for state: ToolCallApprovalState) -> AnyShapeStyle {
        switch state {
        case .pending:  return AnyShapeStyle(Color.orange.opacity(0.1))
        case .rejected: return AnyShapeStyle(Color.red.opacity(0.08))
        case .edited:   return AnyShapeStyle(Color.blue.opacity(0.08))
        case .approved: return AnyShapeStyle(.fill.quaternary)
        }
    }

    private func accessibilityLabel(for state: ToolCallApprovalState, name: String) -> String {
        switch state {
        case .pending:  return "Tool call \(name), waiting for approval"
        case .approved: return "Tool call \(name)"
        case .edited:   return "Tool call \(name), edited before execution"
        case .rejected: return "Tool call \(name), rejected by user"
        }
    }
}

#Preview("Text Only") {
    MessagePartsView(parts: [.text("Hello world")], role: .assistant)
}

#Preview("Tool Call") {
    MessagePartsView(parts: [.toolCall(id: "1", name: "get_weather", arguments: "{\"city\": \"London\"}")], role: .assistant)
}

#Preview("Pending Tool Call") {
    MessagePartsView(
        parts: [.toolCall(id: "1", name: "send_email", arguments: "{\"to\": \"user@example.com\", \"subject\": \"Hi\"}", state: .pending)],
        role: .assistant,
        approvalCoordinator: ToolCallApprovalCoordinator()
    )
}

#Preview("Mixed Parts") {
    MessagePartsView(parts: [.text("Check this:"), .toolResult(id: "1", content: "Temperature: 18°C")], role: .user)
}
