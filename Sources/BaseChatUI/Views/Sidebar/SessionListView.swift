import SwiftUI
import BaseChatCore

/// Displays the list of chat sessions in the sidebar.
///
/// Supports selection, swipe-to-delete, and swipe-to-rename. Shows an empty
/// state when no sessions exist, prompting the user to create one.
public struct SessionListView: View {

    @Environment(SessionManagerViewModel.self) private var sessionManager

    @State private var sessionToDelete: ChatSessionRecord?
    @State private var sessionToRename: ChatSessionRecord?
    @State private var renameText: String = ""
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        @Bindable var sessionManager = sessionManager

        Group {
        if sessionManager.sessions.isEmpty {
            ContentUnavailableView {
                Label("No Chats", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Tap the + button to start a new chat.")
            }
        } else {
            List(sessionManager.sessions, selection: $sessionManager.activeSession) { session in
                SessionRowView(session: session)
                    .tag(session)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            sessionToDelete = session
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            renameText = session.title
                            sessionToRename = session
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
            .alert("Rename Chat", isPresented: .init(
                get: { sessionToRename != nil },
                set: { if !$0 { sessionToRename = nil } }
            )) {
                TextField("Chat title", text: $renameText)
                Button("Cancel", role: .cancel) { sessionToRename = nil }
                Button("Rename") {
                    if let session = sessionToRename {
                        do {
                            try sessionManager.renameSession(session, title: renameText)
                        } catch {
                            errorMessage = "Failed to rename session: \(error.localizedDescription)"
                        }
                    }
                    sessionToRename = nil
                }
            }
            .alert("Delete Chat?", isPresented: .init(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ), presenting: sessionToDelete) { session in
                Button("Delete", role: .destructive) {
                    do {
                        try sessionManager.deleteSession(session)
                    } catch {
                        errorMessage = "Failed to delete session: \(error.localizedDescription)"
                    }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) { sessionToDelete = nil }
            } message: { session in
                Text("This will permanently delete \"\(session.title)\" and all its messages.")
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
        }
        }
        .animation(.default, value: sessionManager.sessions.isEmpty)
    }
}

#Preview("Empty State") {
    SessionListView()
        .environment(SessionManagerViewModel())
}
