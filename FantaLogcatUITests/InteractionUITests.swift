import XCTest

@MainActor
final class InteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testChangingSettingsAppliesImmediately() {
        app = XCUIApplication()
        defer { app.terminate() }
        launchSettings(reset: true)

        let english = languageOption("settings.language.english")
        let language = languagePicker
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()
        XCTAssertTrue(waitForLanguage("english", in: language))
        let redact = redactExportsToggle(true)
        XCTAssertTrue(redact.waitForExistence(timeout: 5))
        redact.click()
        XCTAssertTrue(redactExportsToggle(false).waitForExistence(timeout: 5))

        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        XCTAssertTrue(liveLanguage("english").waitForExistence(timeout: 5))
        XCTAssertTrue(liveRedaction("false").waitForExistence(timeout: 5))
        reopenSettings()

        XCTAssertTrue(waitForLanguage("english", in: languagePicker))
        XCTAssertTrue(redactExportsToggle(false).waitForExistence(timeout: 5))
    }

    func testSearchAddAndClearUseVisibleButtons() {
        app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = persistenceIndependentArguments
            + ["--ui-testing-search", "--ui-testing-reset"]
        app.launch()

        let input = app.textFields["logSearch.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("Unity")

        let add = app.buttons["logSearch.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        XCTAssertTrue(app.staticTexts["Unity"].waitForExistence(timeout: 5))

        let clear = app.buttons["logSearch.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        XCTAssertFalse(app.staticTexts["Unity"].exists)
    }

    private func launchSettings(reset: Bool) {
        app.launchArguments = persistenceIndependentArguments + ["--ui-testing-settings"]
        if reset {
            app.launchArguments.append("--ui-testing-reset")
        }
        app.launch()
    }

    private var persistenceIndependentArguments: [String] {
        ["-ApplePersistenceIgnoreState", "YES"]
    }

    private func languageOption(_ identifier: String) -> XCUIElement {
        app.radioButtons[identifier]
    }

    private var languagePicker: XCUIElement {
        app.descendants(matching: .any)["settings.language"]
    }

    private func redactExportsToggle(_ value: Bool) -> XCUIElement {
        app.checkBoxes["settings.capture.redactExports.\(value)"]
    }

    private func liveLanguage(_ value: String) -> XCUIElement {
        app.staticTexts["uiTesting.live.language.\(value)"]
    }

    private func liveRedaction(_ value: String) -> XCUIElement {
        app.staticTexts["uiTesting.live.redaction.\(value)"]
    }

    private func reopenSettings() {
        let reopen = app.buttons["uiTesting.settings.reopen"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.click()
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 5))
    }

    private func waitForLanguage(_ language: String, in element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", language),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
