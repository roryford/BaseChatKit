import XCTest

/// Shared helpers for all XCUITest suites in BaseChatDemoUITests.
extension XCTestCase {

    // MARK: - Sidebar

    /// Shows the sidebar if the "Show Sidebar" button is visible (e.g. on iPad or compact layout).
    func showSidebarIfNeeded(app: XCUIApplication) {
        let sidebarButton = app.buttons["Show Sidebar"]
        if sidebarButton.waitForExistence(timeout: 2), sidebarButton.isHittable {
            sidebarButton.tap()
            // Allow the sidebar animation to complete
            _ = app.staticTexts["Chats"].waitForExistence(timeout: 2)
        }
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
}
