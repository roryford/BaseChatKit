import SwiftUI
import BaseChatUI

struct ChatScreen: View {
    var body: some View { ChatView(showModelManagement: .constant(false)) { EmptyView() } }
}
