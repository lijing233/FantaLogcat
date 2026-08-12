import XCTest

@MainActor
final class InteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testClosingSettingsDiscardsLanguageChange() {
        launchSettings(reset: true)

        let english = languageOption("settings.language.english")
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()
        XCTAssertTrue(waitUntilSelected(english))

        let close = app.buttons["settings.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()

        app.terminate()
        launchSettings(reset: false)

        let chinese = languageOption("settings.language.chinese")
        XCTAssertTrue(chinese.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilSelected(chinese))
    }

    func testSavingSettingsPersistsLanguageChange() {
        launchSettings(reset: true)

        let english = languageOption("settings.language.english")
        XCTAssertTrue(english.waitForExistence(timeout: 5))
        english.click()
        XCTAssertTrue(waitUntilSelected(english))

        let save = app.buttons["settings.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()

        app.terminate()
        launchSettings(reset: false)

        let persistedEnglish = languageOption("settings.language.english")
        XCTAssertTrue(persistedEnglish.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilSelected(persistedEnglish))
    }

    func testSearchAddAndClearUseVisibleButtons() {
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
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
