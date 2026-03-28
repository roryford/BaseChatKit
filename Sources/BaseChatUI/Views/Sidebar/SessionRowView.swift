import SwiftUI
import BaseChatCore

/// A single row in the session list showing the chat title and relative timestamp.
public struct SessionRowView: View {

    public let session: ChatSession

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.headline)
                .lineLimit(1)

            Text(session.updatedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), updated \(session.updatedAt, style: .relative) ago")
    }
}
