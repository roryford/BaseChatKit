import XCTest

final class ModelManagementUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
    }

    // MARK: - Sheet Presentation

    func testModelButtonOpensSheet() throws {
        openModelManagementSheet()

        let selectTab = app.segmentedControls.buttons["Select"]
        XCTAssertTrue(selectTab.waitForExistence(timeout: 3), "Select tab should appear in model management sheet")
    }

    // MARK: - Tab Switching

    func testCanSwitchBetweenTabs() throws {
        openModelManagementSheet()

        // Verify all three tabs exist
        let selectTab = app.segmentedControls.buttons["Select"]
        let downloadTab = app.segmentedControls.buttons["Download"]
        let storageTab = app.segmentedControls.buttons["Storage"]

        XCTAssertTrue(selectTab.exists, "Select tab should exist")
        XCTAssertTrue(downloadTab.exists, "Download tab should exist")
        XCTAssertTrue(storageTab.exists, "Storage tab should exist")

        // Switch to Download tab
        downloadTab.tap()
        // Should see "Recommended for Your Device" or search field
        let recommendedSection = app.staticTexts["Recommended for Your Device"]
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            recommendedSection.waitForExistence(timeout: 3) || searchField.waitForExistence(timeout: 3),
            "Download tab content should be visible after tapping Download tab"
        )

        // Switch to Storage tab
        storageTab.tap()
        let storageOverview = app.staticTexts["Storage Overview"]
        XCTAssertTrue(storageOverview.waitForExistence(timeout: 3), "Storage tab content should be visible after tapping Storage tab")

        // Switch back to Select tab
        selectTab.tap()
        // Give it a moment to render
        sleep(1)
        takeScreenshot(name: "Select-Tab-After-Switch")
    }

    // MARK: - Select Tab Interaction

    func testSelectTabShowsModels() throws {
        openModelManagementSheet()

        // Check if models are listed or "No Models Available" is shown
        let noModels = app.staticTexts["No Models Available"]
        let foundationModel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Foundation'")).firstMatch

        let hasContent = noModels.waitForExistence(timeout: 3) || foundationModel.waitForExistence(timeout: 3)
        XCTAssertTrue(hasContent, "Select tab should show either models or empty state")

        takeScreenshot(name: "Select-Tab-Content")
    }

    func testSelectTabModelRowIsTappable() throws {
        openModelManagementSheet()
        takeScreenshot(name: "Select-Tab-Open")

        // Find a selectable model row in the sheet. The accessibility label now
        // includes model metadata, so look for the first hittable non-tab button.
        let allButtons = app.buttons.allElementsBoundByIndex
        var sheetModelButton: XCUIElement?
        for button in allButtons {
            guard button.isHittable else { continue }
            if ["Select", "Download", "Storage", "Done"].contains(button.label) {
                continue
            }
            if button.frame.minY > 120 {
                sheetModelButton = button
                break
            }
        }

        guard let modelRow = sheetModelButton else {
            let noModels = app.staticTexts["No Models Available"]
            if noModels.waitForExistence(timeout: 2) {
                takeScreenshot(name: "Select-Tab-No-Models")
                return
            }

            takeScreenshot(name: "Select-Tab-No-Hittable-Model-Row")
            XCTFail("No hittable model row found in the sheet")
            return
        }

        print("MODEL ROW in sheet: label='\(modelRow.label)' hittable=\(modelRow.isHittable) frame=\(modelRow.frame)")
        XCTAssertTrue(modelRow.isHittable, "Model row in sheet should be hittable")

        // Tap it - should dismiss the sheet
        modelRow.tap()
        sleep(1)

        // Check if sheet dismissed
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            takeScreenshot(name: "Select-Tab-Sheet-Still-Open-After-Tap")
            XCTFail("Sheet should have dismissed after selecting a model, but it's still open")
        } else {
            takeScreenshot(name: "Select-Tab-Sheet-Dismissed")
        }
    }

    // MARK: - Download Tab Interaction

    func testDownloadTabShowsRecommendations() throws {
        openModelManagementSheet()

        app.segmentedControls.buttons["Download"].tap()
        sleep(1)

        takeScreenshot(name: "Download-Tab-Content")

        // Check for recommendations section
        let recommended = app.staticTexts["Recommended for Your Device"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 5), "Should show recommended models section")

        // Check for at least one downloadable model
        let modelNames = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'SmolLM' OR label CONTAINS[c] 'Phi' OR label CONTAINS[c] 'Mistral' OR label CONTAINS[c] 'Llama' OR label CONTAINS[c] 'Qwen'"
        ))
        XCTAssertGreaterThan(modelNames.count, 0, "Should show at least one recommended model")
    }

    func testDownloadTabSearchFieldIsInteractive() throws {
        openModelManagementSheet()

        app.segmentedControls.buttons["Download"].tap()
        sleep(1)

        let searchField = app.textFields["Search HuggingFace models"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should exist on Download tab")
        XCTAssertTrue(searchField.isHittable, "Search field should be hittable")

        searchField.tap()
        searchField.typeText("llama")
        takeScreenshot(name: "Download-Tab-Search-Typed")
    }

    func testDownloadButtonIsHittable() throws {
        openModelManagementSheet()

        app.segmentedControls.buttons["Download"].tap()
        sleep(1)

        // Look for download buttons (arrow.down.circle)
        let downloadButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Download'"))

        if downloadButtons.count > 0 {
            let firstDownload = downloadButtons.firstMatch
            XCTAssertTrue(firstDownload.isHittable, "Download button should be hittable")
            takeScreenshot(name: "Download-Tab-Button-Found")
        } else {
            takeScreenshot(name: "Download-Tab-No-Buttons")
            // Not a failure - models might already be downloaded
        }
    }

    // MARK: - Storage Tab

    func testStorageTabShowsOverview() throws {
        openModelManagementSheet()

        app.segmentedControls.buttons["Storage"].tap()
        sleep(1)

        takeScreenshot(name: "Storage-Tab-Content")

        let totalUsed = app.staticTexts["Total Used"]
        XCTAssertTrue(totalUsed.waitForExistence(timeout: 3), "Storage tab should show Total Used label")

        let modelsDirectory = app.staticTexts["Models Directory"]
        XCTAssertTrue(modelsDirectory.exists, "Storage tab should show Models Directory label")
    }

    // MARK: - Done Button

    func testDoneButtonDismissesSheet() throws {
        openModelManagementSheet()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3), "Done button should exist")
        XCTAssertTrue(doneButton.isHittable, "Done button should be hittable")

        doneButton.tap()

        // Sheet should dismiss
        XCTAssertFalse(doneButton.waitForExistence(timeout: 3), "Sheet should dismiss after tapping Done")
    }

    // MARK: - Comprehensive Interaction Audit

    func testAllSheetElementsAreInteractive() throws {
        openModelManagementSheet()

        let controls = [
            app.segmentedControls.buttons["Select"],
            app.segmentedControls.buttons["Download"],
            app.segmentedControls.buttons["Storage"],
            app.buttons["Done"]
        ]

        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 3), "\(control.label) should exist")
            XCTAssertTrue(control.isHittable, "\(control.label) should be hittable")
        }

        takeScreenshot(name: "All-Buttons-Hittable")
    }

    private func openModelManagementSheet() {
        openModelManagementIfNeeded(app: app)

        let selectTab = app.segmentedControls.buttons["Select"]
        guard selectTab.waitForExistence(timeout: 5) else {
            takeScreenshot(name: "Sidebar-No-Model-Button")
            XCTFail("Model management sheet did not open")
            return
        }
    }

    private func takeScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
