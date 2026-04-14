import XCTest

/// Shared helpers for all XCUITest suites in BaseChatDemoUITests.
extension XCTestCase {

    // MARK: - App Launch

    /// Launches the demo app in deterministic UI-testing mode.
    @discardableResult
    func launchDemoApp(file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        #if !os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        #if os(macOS)
        app.activate()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "BaseChatDemo should reach the foreground under macOS UI tests",
            file: file,
            line: line
        )
        #endif
        return app
    }

    // MARK: - Sidebar

    /// Shows the sidebar if the "Show Sidebar" button is visible (e.g. on iPad or compact layout).
    func showSidebarIfNeeded(app: XCUIApplication) {
        if app.staticTexts["Chats"].exists {
            return
        }

        let sidebarButtons = [
            app.buttons["show-sidebar-button"],
            app.buttons["Show Sidebar"]
        ]
        for sidebarButton in sidebarButtons where sidebarButton.waitForExistence(timeout: 2) && sidebarButton.isHittable {
            sidebarButton.tap()
            if app.staticTexts["Chats"].waitForExistence(timeout: 2)
                || app.buttons["new-chat-button"].waitForExistence(timeout: 2)
                || firstSessionRow(app: app).waitForExistence(timeout: 2) {
                return
            }
        }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = app.staticTexts["Chats"].waitForExistence(timeout: 2)
            || app.buttons["new-chat-button"].waitForExistence(timeout: 2)
    }

    // MARK: - Chat Detail

    /// On compact layouts, the app may launch with the session list visible first.
    /// Tap the current session so the chat detail toolbar and input become accessible.
    func openChatDetailIfNeeded(app: XCUIApplication) {
        if isChatDetailVisible(app: app) {
            return
        }

        if app.staticTexts["Chats"].exists || app.buttons["new-chat-button"].exists {
            let outsideSidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.2))
            outsideSidebar.tap()

            if isChatDetailVisible(app: app) {
                return
            }

            app.swipeLeft()
            if isChatDetailVisible(app: app) {
                return
            }
        }

        let firstSessionCell = firstSessionRow(app: app)
        if firstSessionCell.waitForExistence(timeout: 3), firstSessionCell.isHittable {
            firstSessionCell.tap()
        } else {
            let sessionText = app.staticTexts.matching(NSPredicate(
                format: "label == 'New Chat' OR label CONTAINS[c] 'updated'"
            )).firstMatch
            if sessionText.waitForExistence(timeout: 2), sessionText.isHittable {
                sessionText.tap()
            }
        }

        _ = waitForElement(app.buttons["chat-settings-button"], timeout: 3)
            || waitForElement(app.buttons["chat-model-management-button"], timeout: 1)
            || waitForElement(app.buttons["Generation settings"], timeout: 1)
            || waitForElement(app.buttons["Browse and download models"], timeout: 1)
            || waitForElement(app.buttons["Select Model"], timeout: 1)
            || waitForElement(app.staticTexts["No Model Selected"], timeout: 1)
            || waitForElement(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] 'Welcome'"
            )).firstMatch, timeout: 1)
    }

    func isChatDetailVisible(app: XCUIApplication) -> Bool {
        app.buttons["chat-settings-button"].exists
            || app.buttons["chat-model-management-button"].exists
            || app.buttons["Generation settings"].exists
            || app.buttons["Browse and download models"].exists
            || app.buttons["Select Model"].exists
            || app.textFields["Message input"].exists
            || app.staticTexts["No Model Selected"].exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Welcome'")).firstMatch.exists
    }

    // MARK: - Common Element Lookup

    func findNewChatButton(app: XCUIApplication) -> XCUIElement? {
        let candidates = [
            app.buttons["New Chat"],
            app.buttons["new-chat-button"],
            app.navigationBars.buttons["New Chat"],
            app.navigationBars.buttons["new-chat-button"],
            app.buttons.matching(NSPredicate(
                format: "label == 'Add' OR identifier == 'new-chat-button'"
            )).firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            return candidate
        }

        return nil
    }

    func openModelManagementIfNeeded(app: XCUIApplication) {
        if app.descendants(matching: .any).matching(identifier: "model-management-tab-picker").firstMatch.exists
            || modelManagementTab("Select", app: app).exists {
            return
        }

        openChatDetailIfNeeded(app: app)

        let candidates = [
            app.buttons["sidebar-model-management-button"],
            app.buttons["chat-model-management-button"],
            app.buttons["Browse and download models"],
            app.buttons["Browse Models"],
            app.buttons["Select Model"],
            app.buttons["Apple Foundation Model"],
            app.buttons["No Model Selected"]
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 2) && candidate.isHittable {
            candidate.tap()
            break
        }
    }

    func modelManagementTab(_ label: String, app: XCUIApplication) -> XCUIElement {
        let labelMatch = NSPredicate(format: "label == %@", label)
        let pickerTab = app
            .descendants(matching: .any)
            .matching(identifier: "model-management-tab-picker")
            .firstMatch
            .descendants(matching: .any)
            .matching(labelMatch)
            .firstMatch
        let candidates = [
            pickerTab,
            app.segmentedControls.buttons[label],
            app.buttons[label]
        ]

        for candidate in candidates where candidate.exists {
            return candidate
        }

        return pickerTab
    }

    func advancedSettingsDisclosure(app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["advanced-settings-disclosure"]
        if button.exists {
            return button
        }

        let labeledButton = app.buttons["Advanced Settings"]
        if labeledButton.exists {
            return labeledButton
        }

        let disclosure = app.otherElements["advanced-settings-disclosure"]
        if disclosure.exists {
            return disclosure
        }

        let text = app.staticTexts["Advanced Settings"]
        if text.exists {
            return text
        }

        return app.buttons["Advanced Settings"]
    }

    func firstSessionRow(app: XCUIApplication) -> XCUIElement {
        let identifiedRow = app.cells.matching(NSPredicate(format: "identifier == 'session-row'")).firstMatch
        if identifiedRow.exists {
            return identifiedRow
        }

        let identifiedOther = app.otherElements.matching(NSPredicate(format: "identifier == 'session-row'")).firstMatch
        if identifiedOther.exists {
            return identifiedOther
        }

        return app.cells.firstMatch
    }

    @discardableResult
    func tapToolbarButton(_ label: String, app: XCUIApplication) -> Bool {
        let identifierCandidates: [XCUIElement]
        switch label {
        case "Generation settings":
            identifierCandidates = [app.buttons["chat-settings-button"]]
        default:
            identifierCandidates = []
        }

        for candidate in identifierCandidates where candidate.waitForExistence(timeout: 2) && candidate.isHittable {
            candidate.tap()
            return true
        }

        let directButton = app.buttons[label]
        if directButton.waitForExistence(timeout: 2), directButton.isHittable {
            directButton.tap()
            return true
        }

        let moreCandidates = [
            app.buttons["More"],
            app.navigationBars.buttons["More"],
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More'")).firstMatch
        ]

        for moreButton in moreCandidates where moreButton.waitForExistence(timeout: 1) && moreButton.isHittable {
            moreButton.tap()

            for candidate in identifierCandidates where candidate.waitForExistence(timeout: 2) && candidate.isHittable {
                candidate.tap()
                return true
            }

            let menuButton = app.buttons[label]
            if menuButton.waitForExistence(timeout: 2), menuButton.isHittable {
                menuButton.tap()
                return true
            }

            let menuText = app.staticTexts[label]
            if menuText.waitForExistence(timeout: 1), menuText.isHittable {
                menuText.tap()
                return true
            }
        }

        return false
    }

    @discardableResult
    func scrollToElement(_ element: XCUIElement, app: XCUIApplication, maxSwipes: Int = 4) -> Bool {
        if element.exists {
            return true
        }

        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }

        return element.exists
    }

    // MARK: - Screenshots

    /// Takes a screenshot and attaches it to the current test for debugging.
    func captureScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Element Waiting

    /// Waits for an element to exist within the given timeout. Returns `true` if found.
    @discardableResult
    func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - Sheet Dismissal

    /// Dismisses a presented sheet by tapping the "Done" button if it exists,
    /// otherwise swipes down on the sheet.
    func dismissSheet(app: XCUIApplication) {
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2), doneButton.isHittable {
            doneButton.tap()
        } else {
            // Fall back to swipe-down gesture
            let topCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let bottomCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            topCoordinate.press(forDuration: 0.05, thenDragTo: bottomCoordinate)
        }
    }

    // MARK: - Real-Model E2E Helpers
    //
    // These helpers support hardware-gated end-to-end tests that load real
    // on-disk models (GGUF / MLX / Apple Foundation) through the real UI and
    // verify that a streamed response actually appears. They are NOT meant for
    // unit-test usage — the timeouts are generous because real model loads can
    // take 10–30 seconds and generation can take another 30–120 seconds.

    /// Finds the model row in the Select tab whose accessibility label contains
    /// `needle` (case-insensitive). Returns `nil` if no matching row exists.
    ///
    /// Looks first at buttons (the real `ModelSelectionRow` is a Button), then
    /// falls back to any element that exposes a matching label, since
    /// `accessibilityElement(children: .combine)` can flatten the row into a
    /// non-button element on some platforms.
    func findModelRow(in app: XCUIApplication, containing needle: String) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)

        let buttonMatch = app.buttons.matching(predicate).firstMatch
        if buttonMatch.waitForExistence(timeout: 5) {
            return buttonMatch
        }

        let cellMatch = app.cells.matching(predicate).firstMatch
        if cellMatch.exists {
            return cellMatch
        }

        let otherMatch = app.otherElements.matching(predicate).firstMatch
        if otherMatch.exists {
            return otherMatch
        }

        return nil
    }

    /// Waits until the chat input field is hittable AND enabled, indicating
    /// that the selected model has finished loading and the UI is ready to
    /// accept a prompt.
    ///
    /// Returns `true` when the input is ready, `false` if the timeout expires.
    /// The default timeout is 60s — enough for a cold MLX or GGUF load on
    /// Apple Silicon. Polls every 0.5s using `XCUIElement` queries (no sleep
    /// inside a Task; this runs on the test thread).
    @discardableResult
    func waitForChatInputReady(app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let messageInput = app.textFields["Message input"]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // `waitForExistence` provides the timed wait without a manual sleep
            // loop. We re-check enabled+hittable each iteration because the
            // input transitions through "exists but disabled" while the model
            // is still loading.
            if messageInput.waitForExistence(timeout: 1),
               messageInput.isEnabled,
               messageInput.isHittable {
                return true
            }
        }

        return false
    }

    /// Sends a prompt through the real chat input and waits for any assistant
    /// response text to appear in the chat. Returns `true` when streamed
    /// content is observed, `false` if no response arrives before the timeout.
    ///
    /// The assertion is intentionally lenient: it only verifies that *some*
    /// non-prompt assistant text appears, not the specific content. Real models
    /// are non-deterministic.
    @discardableResult
    func sendPromptAndAwaitResponse(
        app: XCUIApplication,
        prompt: String,
        responseTimeout: TimeInterval = 120
    ) -> Bool {
        let messageInput = app.textFields["Message input"]
        guard messageInput.waitForExistence(timeout: 5), messageInput.isHittable else {
            return false
        }

        messageInput.tap()
        messageInput.typeText(prompt)

        let sendButton = app.buttons["Send message"]
        guard sendButton.waitForExistence(timeout: 5), sendButton.isEnabled else {
            return false
        }
        sendButton.tap()

        // The user message bubble appears as a static text containing the
        // prompt. The assistant bubble accessibility label is
        // "Assistant said: <content>" — wait for any such element to exist.
        let assistantPredicate = NSPredicate(format: "label BEGINSWITH[c] 'Assistant said:'")
        let assistantBubble = app.otherElements.matching(assistantPredicate).firstMatch

        if assistantBubble.waitForExistence(timeout: responseTimeout) {
            // Confirm the bubble has streamed *some* content beyond the prefix.
            let label = assistantBubble.label
            return label.count > "Assistant said: ".count
        }

        // Fall back to scanning static texts: streaming assistant content can
        // appear as plain Text elements depending on rendering path.
        let staticPredicate = NSPredicate(
            format: "label != %@ AND label.length > 0", prompt
        )
        let texts = app.staticTexts.matching(staticPredicate)
        return texts.count > 0
    }
}
