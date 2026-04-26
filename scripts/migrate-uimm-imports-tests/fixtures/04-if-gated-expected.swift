import SwiftUI
#if Ollama
import BaseChatUI
import BaseChatUIModelManagement
#endif

struct OllamaGated: View {
    var body: some View {
        #if Ollama
        APIEndpointEditorView()
        #else
        EmptyView()
        #endif
    }
}
