import SwiftUI
#if Ollama
import BaseChatUI
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
