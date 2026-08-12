import XCTest

@MainActor
final class InteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testClosingSettingsDiscardsLanguageChange() {
        app = XCUIApplication()
        defer { app.terminate() }
        launchSettings(reset: true)

        let english = languageOption("settings.language.english")
        let language = languagePicker
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()
        XCTAssertTrue(waitForLanguage("english", in: language))

        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        app.terminate()
        launchSettings(reset: false)

        let relaunchedLanguage = languagePicker
        XCTAssertTrue(relaunchedLanguage.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLanguage("chinese", in: relaunchedLanguage))
    }

    func testSavingSettingsPersistsLanguageChange() {
        app = XCUIApplication()
        defer { app.terminate() }
        launchSettings(reset: true)

        let english = languageOption("settings.language.english")
        let language = languagePicker
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()
        XCTAssertTrue(waitForLanguage("english", in: language))

        let save = app.buttons["settings.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()

        app.terminate()
        launchSettings(reset: false)

        let relaunchedLanguage = languagePicker
        XCTAssertTrue(relaunchedLanguage.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLanguage("english", in: relaunchedLanguage))
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

    private func waitForLanguage(_ language: String, in element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", language),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
