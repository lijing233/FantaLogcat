import Foundation
import XCTest
@testable import FantaLogcat

final class AppSettingsTests: XCTestCase {
    func testUserDefaultsStoreRoundTripsLanguageAndNormalizedCaptureSettings() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        store.save(AppSettings(
            language: .english,
            capture: .init(historyLines: 999, maxEvents: 500, maxTextBytes: 1, redactExportsByDefault: false)
        ))

        XCTAssertEqual(store.settings.language, .english)
        XCTAssertEqual(store.settings.capture.historyLines, 500)
        XCTAssertEqual(store.settings.capture.maxEvents, 1_000)
        XCTAssertEqual(store.settings.capture.maxTextBytes, 8 * 1_024 * 1_024)
        XCTAssertFalse(store.settings.capture.redactExportsByDefault)
    }
}
