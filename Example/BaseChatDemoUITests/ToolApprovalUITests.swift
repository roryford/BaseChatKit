import XCTest

/// Deterministic UI tests for the tool-approval flow surfaces.
///
/// Runs against the demo app launched with `--uitesting`, which swaps in a
/// ``ScriptedBackend`` emitting a canned `.toolCall` for `sample_repo_search`.
/// No live Ollama / MLX / cloud traffic.
///
/// Scope: verify that the flagship-prompt empty state renders and wires a
/// hit-target. The downstream approval sheet + completed-bubble rendering
/// is covered deterministically by ``UIToolApprovalGateTests`` and
/// ``ToolInvocationViewTests`` at the XCTest level, where we can observe
/// `@Observable` state changes directly. XCUITest's sheet-presentation
/// timing is flaky under simulator in the `--uitesting` pathway and would
/// add noise without adding information.
final class ToolApprovalUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_flagshipPromptButton_rendersInEmptyState() {
        let app = launchDemoApp()
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 20),
            "Chat input should become hittable under --uitesting"
        )

        let flagshipButton = app.buttons["flagship-prompt-button"]
        XCTAssertTrue(
            flagshipButton.waitForExistence(timeout: 5),
            "Flagship prompt button should render in the chat empty state"
        )
        XCTAssertTrue(
            flagshipButton.isHittable,
            "Flagship prompt button must be tappable for reviewers to exercise the tool loop"
        )
    }

    func test_sidebarToolPolicyButton_isReachable() {
        let app = launchDemoApp()

        showSidebarIfNeeded(app: app)
        let policyButton = app.buttons["sidebar-tool-policy-button"]
        XCTAssertTrue(
            policyButton.waitForExistence(timeout: 10),
            "Tool-policy picker button should be reachable from the sidebar"
        )
    }
}
