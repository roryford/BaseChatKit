import XCTest

final class CloudAPIUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
    }

    // MARK: - Navigation to API Configuration

    func testOpenAPIConfiguration() throws {
        navigateToAPIConfiguration()
        captureScreenshot(name: "API-Config-Opened")
    }

    func testEmptyStateMessage() throws {
        navigateToAPIConfiguration()

        // When no endpoints are configured, it should show empty state text
        let emptyText = app.staticTexts["No cloud APIs configured."]
        let hasEmptyState = waitForElement(emptyText, timeout: 3)

        captureScreenshot(name: "API-Config-Empty-State")

        // If endpoints already exist, the empty state won't show — that's fine
        if !hasEmptyState {
            // Verify the Endpoints section exists instead
            let endpointsSection = app.staticTexts["Endpoints"]
            XCTAssertTrue(waitForElement(endpointsSection, timeout: 3),
                          "Should show either empty state or Endpoints section")
        }
    }

    func testAddEndpointFlow() throws {
        navigateToAPIConfiguration()

        // Tap the "Add Endpoint" button
        let addButton = app.buttons["Add Endpoint"]
        guard waitForElement(addButton, timeout: 3) else {
            captureScreenshot(name: "API-Config-No-Add-Button")
            XCTFail("Add Endpoint button not found")
            return
        }

        addButton.tap()

        // The editor sheet should appear with "Add Endpoint" title
        let editorTitle = app.staticTexts["Add Endpoint"]
        XCTAssertTrue(waitForElement(editorTitle, timeout: 5),
                      "Endpoint editor should appear with 'Add Endpoint' title")

        // Verify key fields exist
        let displayNameField = app.textFields["Display Name"]
        XCTAssertTrue(waitForElement(displayNameField, timeout: 3),
                      "Display Name field should exist in editor")

        let serverURLField = app.textFields["Server URL"]
        XCTAssertTrue(waitForElement(serverURLField, timeout: 3),
                      "Server URL field should exist in editor")

        let modelNameField = app.textFields["Model Name"]
        XCTAssertTrue(waitForElement(modelNameField, timeout: 3),
                      "Model Name field should exist in editor")

        // API Key field (SecureField) — look for it
        let apiKeyField = app.secureTextFields["API Key"]
        // API key may not be visible if the default provider doesn't require one
        if apiKeyField.exists {
            captureScreenshot(name: "API-Editor-With-API-Key")
        }

        captureScreenshot(name: "API-Editor-Fields")

        // Dismiss the editor
        let cancelButton = app.buttons["Cancel"]
        if waitForElement(cancelButton, timeout: 2) {
            cancelButton.tap()
        } else {
            dismissSheet(app: app)
        }
    }

    func testDismissAPIConfig() throws {
        navigateToAPIConfiguration()

        let doneButton = app.navigationBars["Cloud APIs"].buttons["Done"]
        guard waitForElement(doneButton, timeout: 3) else {
            captureScreenshot(name: "API-Config-No-Done-Button")
            XCTFail("Done button not found in API configuration")
            return
        }

        doneButton.tap()

        if apiTitleStillVisible(app: app) {
            dismissSheet(app: app)
        }

        // The "Cloud APIs" title should no longer be visible
        let apiTitle = app.staticTexts["Cloud APIs"]
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: apiTitle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappeared], timeout: 3),
            .completed,
            "API configuration sheet should be dismissed after tapping Done"
        )

        captureScreenshot(name: "API-Config-Dismissed")
    }

    // MARK: - Helpers

    /// Navigates from the main app to the API Configuration view.
    /// Path: Settings button -> Advanced Settings -> Manage Cloud APIs
    private func navigateToAPIConfiguration() {
        openChatDetailIfNeeded(app: app)

        // Step 1: Open settings
        if !tapToolbarButton("Generation settings", app: app) {
            let gearButton = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'Settings' OR label CONTAINS[c] 'gear'"
            )).firstMatch
            guard waitForElement(gearButton, timeout: 3), gearButton.isHittable else {
                captureScreenshot(name: "API-Nav-No-Settings-Button")
                XCTFail("Could not find settings button to navigate to API configuration")
                return
            }
            gearButton.tap()
        }

        // Wait for settings sheet
        let settingsTitle = app.staticTexts["Generation Settings"]
        guard waitForElement(settingsTitle, timeout: 5) else {
            captureScreenshot(name: "API-Nav-Settings-Not-Opened")
            XCTFail("Settings sheet did not open")
            return
        }

        // Step 2: Expand Advanced Settings disclosure
        let manageAPIsControl = app.buttons["Manage Cloud APIs"].exists
            ? app.buttons["Manage Cloud APIs"]
            : app.staticTexts["Manage Cloud APIs"]

        let advancedDisclosure = advancedSettingsDisclosure(app: app)
        if !scrollToElement(manageAPIsControl, app: app, maxSwipes: 1),
           waitForElement(advancedDisclosure, timeout: 3) {
            advancedDisclosure.tap()
            // Wait for the disclosure to expand
            _ = manageAPIsControl.waitForExistence(timeout: 3)
        }

        // Step 3: Tap "Manage Cloud APIs"
        guard scrollToElement(manageAPIsControl, app: app), waitForElement(manageAPIsControl, timeout: 2) else {
            captureScreenshot(name: "API-Nav-No-Manage-Button")
            // The Cloud API section may be hidden by feature flags
            XCTFail("Manage Cloud APIs button not found — feature may be disabled")
            return
        }

        manageAPIsControl.tap()

        // Wait for the API configuration sheet
        let apiTitle = app.staticTexts["Cloud APIs"]
        guard waitForElement(apiTitle, timeout: 5) else {
            captureScreenshot(name: "API-Nav-Config-Not-Opened")
            XCTFail("API Configuration sheet did not open")
            return
        }
    }

    private func apiTitleStillVisible(app: XCUIApplication) -> Bool {
        app.staticTexts["Cloud APIs"].exists
    }
}
