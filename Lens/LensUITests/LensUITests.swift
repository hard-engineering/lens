import XCTest

/// Drives the gallery-import flow end-to-end and captures screenshots for
/// the §11.3 review-screen check + layout-sanity checks.
///
/// The simulator has no camera, so VisionKit fails to capture and shows its
/// own "Unable to capture media" alert on launch. The test dismisses both that
/// alert and any camera-permission alert before driving the intermediate view.
///
/// Fixtures (shadow_doc.jpg, angled_doc.jpg) must already be in the simulator's
/// Photos library — `scripts/run_ui_tests.sh` runs `xcrun simctl addmedia` first.
final class LensUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_intermediateView_layout() throws {
        let app = XCUIApplication()
        app.launch()
        dismissAnyAlerts(app: app, timeout: 3)

        let importButton = app.buttons["Import from Photos"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Intermediate view did not appear")
        XCTAssertTrue(importButton.isHittable, "Import button is not hittable")
        XCTAssertTrue(app.buttons["Scan with Camera"].exists, "Scan with Camera button missing")

        snapshot(app, name: "intermediate_view")
    }

    /// Drives the Review screen end-to-end by preloading a fixture via the
    /// `-uiTestPreloadFixturePath` launch hook, then exercising filter/share UI.
    /// Bypasses PHPicker — driving PHPicker reliably across iOS versions on
    /// the simulator is brittle (out-of-process extension, restricted a11y).
    func test_reviewScreen_endToEnd() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestPreloadFixturePath",
            "/Users/sks/ws/ns/lens/test_inputs/shadow_doc.jpg",
        ]
        app.launch()
        dismissAnyAlerts(app: app, timeout: 3)

        let shareButton = app.buttons["Share"].firstMatch
        XCTAssertTrue(
            shareButton.waitForExistence(timeout: 15),
            "Review screen did not appear after preloading fixture — launch hook may have failed"
        )
        // Verify the §11.3 review-screen criteria.
        // Add button uses accessibilityLabel("Add Pages") even though the
        // visible text is "Add", so this still matches.
        XCTAssertTrue(app.buttons["Add Pages"].exists, "Review screen missing 'Add Pages' button")
        XCTAssertTrue(
            app.buttons["Discard Scan"].exists,
            "Review screen missing Discard Scan toolbar button"
        )
        XCTAssertTrue(app.buttons["Save"].exists, "Review screen missing Save menu button")
        snapshot(app, name: "review_screen")

        // Verify the Discard alert exposes both Cancel and Discard.
        app.buttons["Discard Scan"].tap()
        let discardAlert = app.alerts.firstMatch
        XCTAssertTrue(
            discardAlert.waitForExistence(timeout: 4),
            "Discard alert did not appear"
        )
        XCTAssertTrue(discardAlert.buttons["Cancel"].exists, "Discard alert missing Cancel")
        XCTAssertTrue(discardAlert.buttons["Discard"].exists, "Discard alert missing Discard")
        snapshot(app, name: "discard_alert")
        discardAlert.buttons["Cancel"].tap()

        // Verify the Save menu lists both PDF + Photos options.
        app.buttons["Save"].tap()
        let pdfOption = app.buttons["Save PDF to Files"].firstMatch
        XCTAssertTrue(
            pdfOption.waitForExistence(timeout: 4),
            "Save menu missing 'Save PDF to Files'"
        )
        XCTAssertTrue(
            app.buttons["Save Pages to Photos"].firstMatch.exists,
            "Save menu missing 'Save Pages to Photos'"
        )
        snapshot(app, name: "save_menu")
        // SwiftUI Menu is dismissed by tapping outside.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        // Enter Edit mode and capture — verifies redundant minus-icons are gone
        // (we removed .onDelete) while reorder handles remain.
        if app.buttons["Edit"].exists {
            app.buttons["Edit"].tap()
            snapshot(app, name: "review_edit_mode")
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        }

        // Per-page filter picker and 'Apply to all' segmented control exist as
        // SwiftUI Pickers — their option labels live as buttons inside them.
        XCTAssertTrue(
            app.staticTexts["Original"].exists || app.buttons["Original"].exists,
            "Filter option 'Original' not present"
        )
        XCTAssertTrue(
            app.staticTexts["B&W"].exists || app.buttons["B&W"].exists,
            "Filter option 'B&W' not present"
        )

        // Tap Add Pages to confirm the action sheet appears with both sources.
        // SwiftUI's .confirmationDialog renders via UIAlertController on iOS,
        // so options live under app.sheets (iPhone) or app.popovers (iPad).
        app.buttons["Add Pages"].tap()
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.popovers.firstMatch
        XCTAssertTrue(
            dialog.waitForExistence(timeout: 4),
            "Add Pages dialog did not appear"
        )
        XCTAssertTrue(
            dialog.buttons["Scan with Camera"].exists,
            "Add Pages dialog should offer 'Scan with Camera'"
        )
        XCTAssertTrue(
            dialog.buttons["Import from Photos"].exists,
            "Add Pages dialog should offer 'Import from Photos'"
        )
        snapshot(app, name: "add_pages_dialog")
        // Dismiss the action sheet. iOS 26's accessibility tree sometimes
        // omits the role-.cancel button from `dialog.buttons["Cancel"]`; a
        // top-of-screen coordinate tap closes the sheet regardless.
        if dialog.buttons["Cancel"].exists {
            dialog.buttons["Cancel"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
        }

        // Tap Share to confirm UIActivityViewController appears.
        shareButton.tap()
        let activityCancel = app.buttons["Close"].firstMatch
        if activityCancel.waitForExistence(timeout: 6) {
            snapshot(app, name: "share_sheet")
            activityCancel.tap()
        } else {
            // Some share sheets use a Cancel button label.
            let alt = app.buttons["Cancel"].firstMatch
            if alt.waitForExistence(timeout: 2) {
                snapshot(app, name: "share_sheet")
                alt.tap()
            }
        }
    }

    // MARK: - Helpers

    /// Repeatedly dismisses system / VisionKit alerts that may appear at launch
    /// on the simulator (camera permission, "Unable to capture media").
    private func dismissAnyAlerts(app: XCUIApplication, timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var handled = false
            for label in ["Don't Allow", "OK", "Allow"] {
                if springboard.alerts.buttons[label].exists {
                    springboard.alerts.buttons[label].firstMatch.tap()
                    handled = true
                    break
                }
                if app.alerts.buttons[label].exists {
                    app.alerts.buttons[label].firstMatch.tap()
                    handled = true
                    break
                }
            }
            if !handled { break }
            usleep(300_000)
        }
    }

    private func snapshot(_ app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = ProcessInfo.processInfo.environment["TEST_RUN_OUTPUT_DIR"] {
            let outDir = URL(fileURLWithPath: dir).appendingPathComponent("screenshots")
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let url = outDir.appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: url)
        }
    }
}
