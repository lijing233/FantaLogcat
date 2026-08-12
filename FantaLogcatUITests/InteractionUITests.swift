import XCTest

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

        let language = app.segmentedControls["settings.language"]
        language.buttons.element(boundBy: 1).click()
        app.buttons["settings.close"].click()

        app.terminate()
        launchSettings(reset: false)

        XCTAssertTrue(
            app.segmentedControls["settings.language"].buttons["简体中文"].isSelected
        )
    }

    func testSavingSettingsPersistsLanguageChange() {
        launchSettings(reset: true)

        let language = app.segmentedControls["settings.language"]
        language.buttons.element(boundBy: 1).click()
        app.buttons["settings.save"].click()

        app.terminate()
        launchSettings(reset: false)

        XCTAssertTrue(
            app.segmentedControls["settings.language"].buttons["English"].isSelected
        )
    }

    func testSearchAddAndClearUseVisibleButtons() {
        app.launchArguments = persistenceIndependentArguments
            + ["--ui-testing-search", "--ui-testing-reset"]
        app.launch()

        app.textFields["logSearch.input"].typeText("Unity")
        app.buttons["logSearch.add"].click()
        XCTAssertTrue(app.staticTexts["Unity"].exists)

        app.buttons["logSearch.clear"].click()
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
}
