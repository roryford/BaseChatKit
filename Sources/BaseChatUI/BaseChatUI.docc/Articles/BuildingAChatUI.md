# Building a Chat UI

Compose BaseChatUI components into a multi-session chat application.

## Overview

This article shows the full layout pattern for an app with a sidebar session list and a main chat area, wired to the two primary view models: ``ChatViewModel`` and ``SessionManagerViewModel``.

### App scaffold

Create both view models at the app level and share the same `InferenceService` between them. ``SessionManagerViewModel`` only manages session metadata — it never touches inference directly. ``ChatViewModel`` drives all generation.

```swift
import BaseChatCore
import BaseChatBackends
import BaseChatUI
import SwiftUI
import SwiftData

@main
struct MyApp: App {
    let inferenceService = InferenceService()
    let chatVM: ChatViewModel
    let sessionVM = SessionManagerViewModel()

    init() {
        BaseChatConfiguration.shared = BaseChatConfiguration(
            appName: "MyApp",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.myapp"
        )
        DefaultBackends.register(with: inferenceService)
        chatVM = ChatViewModel(inferenceService: inferenceService)

        // Connect session title generation to InferenceService
        chatVM.onFirstMessage = { session, firstMessage in
            Task { @MainActor in
                await sessionVM.autoRenameSession(session, firstMessage: firstMessage, inferenceService: inferenceService)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatVM)
                .environment(sessionVM)
        }
        .modelContainer(try! ModelContainerFactory.makeContainer())
    }
}
```

### Root layout with NavigationSplitView

```swift
struct RootView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM
    @Environment(\.modelContext) var modelContext

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            ChatView()
        }
        .task {
            let provider = SwiftDataPersistenceProvider(modelContext: modelContext)
            sessionVM.configure(persistence: provider)
            chatVM.configure(persistence: provider)
            chatVM.refreshModels()
        }
    }
}
```

Both view models share the same ``SwiftDataPersistenceProvider`` instance so session records created by `SessionManagerViewModel` are immediately visible to `ChatViewModel`.

### Switching sessions

When the user selects a session in the sidebar, switch the active chat context:

```swift
struct SessionListView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM

    var body: some View {
        List(sessionVM.sessions, selection: $sessionVM.activeSession) { session in
            SessionRowView(session: session)
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            if let session = newSession {
                chatVM.switchToSession(session)
            }
        }
        .toolbar {
            Button("New Chat", systemImage: "square.and.pencil") {
                let session = try? sessionVM.createSession()
                if let session { chatVM.switchToSession(session) }
            }
        }
    }
}
```

### Customizing the model selection experience

``ChatViewModel`` exposes ``ChatViewModel/onFirstLaunch`` for apps that want to control the initial model selection flow — for example, showing an onboarding sheet instead of auto-selecting the Foundation model:

```swift
chatVM.onFirstLaunch = {
    showOnboardingSheet = true
}
```

When `onFirstLaunch` is `nil`, BaseChatKit auto-selects the Foundation model if ``ChatViewModel/foundationModelProvider`` returns `true`:

```swift
chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
```

### Adding post-generation tasks

Register background tasks that run after each response completes:

```swift
chatVM.postGenerationTasks = [
    AnalyticsLogger(),       // your PostGenerationTask conforming types
    LocalIndexUpdater()
]
```

Tasks run sequentially off `@MainActor`. Errors surface in ``ChatViewModel/backgroundTaskError`` but don't interrupt the session.

## Next Steps

- See ``GenerationSettingsView`` to give users control over temperature and prompt templates
- See `BaseChatUIModelManagement.ModelManagementSheet` for the combined model selection, download, and storage UI (now in the peeled `BaseChatUIModelManagement` product — `import` it explicitly)
- See ``BaseChatConfiguration/Features`` to hide UI features that don't apply to your deployment
