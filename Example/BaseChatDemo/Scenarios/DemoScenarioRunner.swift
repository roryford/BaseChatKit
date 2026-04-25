import Foundation
import BaseChatInference
import BaseChatUI

/// Composition seam shared by every entry point that launches a scenario:
/// empty-state cards, the toolbar `Demos` menu, and the `--bck-demo-scenario`
/// launch-arg path on cold launch.
@MainActor
enum DemoScenarioRunner {

    /// Executes `scenario` against the supplied view models.
    ///
    /// Sequence:
    /// 1. Bail when generation is in flight — avoids racing the new session
    ///    against an active stream.
    /// 2. Reset the registry to the baseline tool set, then invoke the
    ///    scenario's optional `configure` closure to install variants.
    /// 3. Create a new session and activate it. The activation triggers
    ///    `DemoContentView`'s `onChange(of: sessionManager.activeSession)`,
    ///    which calls `viewModel.switchToSession` — no need to call it here.
    /// 4. Prefill the composer and, when `autoSend` is true, send.
    static func run(
        _ scenario: DemoScenario,
        chat: ChatViewModel,
        sessions: SessionManagerViewModel,
        registry: ToolRegistry,
        sandboxRoot: URL
    ) async {
        guard !chat.isGenerating else { return }

        DemoTools.resetToDefaults(on: registry, root: sandboxRoot)
        scenario.configure?(registry)

        do {
            let session = try sessions.createSession(title: scenario.title)
            sessions.activeSession = session
        } catch {
            chat.errorMessage = "Failed to start scenario: \(error.localizedDescription)"
            return
        }

        chat.inputText = scenario.prompt
        if scenario.autoSend {
            await chat.sendMessage()
        }
    }
}
