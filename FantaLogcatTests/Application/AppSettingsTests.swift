import Foundation
import XCTest
@testable import FantaLogcat

final class AppSettingsTests: XCTestCase {
    func testSaveWritesOneAtomicNormalizedSettingsBlob() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        try store.save(AppSettings(
            language: .english,
            appearance: .dark,
            defaultDeviceDestination: .toolbox,
            capture: .init(historyLines: 999, maxEvents: 500, maxTextBytes: 1, redactExportsByDefault: false)
        ))

        let data = try XCTUnwrap(defaults.data(forKey: AppSettings.storageKey))
        let stored = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(stored.language, .english)
        XCTAssertEqual(stored.appearance, .dark)
        XCTAssertEqual(stored.defaultDeviceDestination, .toolbox)
        XCTAssertEqual(stored.capture.historyLines, 500)
        XCTAssertEqual(stored.capture.maxEvents, 1_000)
        XCTAssertEqual(stored.capture.maxTextBytes, 8 * 1_024 * 1_024)
        XCTAssertFalse(stored.capture.redactExportsByDefault)
        XCTAssertNil(defaults.object(forKey: AppLanguage.storageKey))
        XCTAssertNil(defaults.object(forKey: LogCaptureSettings.storageKey))
    }

    func testReadMigratesLegacySplitKeysToAtomicBlob() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(
            try JSONEncoder().encode(LogCaptureSettings(historyLines: 100, maxEvents: 5_000, maxTextBytes: 16 * 1_024 * 1_024, redactExportsByDefault: false)),
            forKey: LogCaptureSettings.storageKey
        )

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.capture.historyLines, 100)
        XCTAssertNotNil(defaults.data(forKey: AppSettings.storageKey))
    }

    func testOldAtomicBlobWithoutAppearanceDefaultsToSystem() throws {
        struct LegacyAppSettings: Encodable {
            let language: AppLanguage
            let capture: LogCaptureSettings
        }

        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(
            try JSONEncoder().encode(LegacyAppSettings(
                language: .english,
                capture: LogCaptureSettings(historyLines: 300)
            )),
            forKey: AppSettings.storageKey
        )

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.defaultDeviceDestination, .logs)
        XCTAssertEqual(settings.capture.historyLines, 300)
    }

    func testCorruptAtomicBlobFallsBackToValidLegacyValues() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(Data("invalid".utf8), forKey: AppSettings.storageKey)
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(try JSONEncoder().encode(LogCaptureSettings(historyLines: 200)), forKey: LogCaptureSettings.storageKey)

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(settings.capture.historyLines, 200)
    }

    func testCorruptLegacyValuesUseNormalizedDefaults() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("unsupported", forKey: AppLanguage.storageKey)
        defaults.set(Data("invalid".utf8), forKey: LogCaptureSettings.storageKey)

        let settings = UserDefaultsAppSettingsStore(defaults: defaults).settings

        XCTAssertEqual(settings, AppSettings(language: .chinese, capture: LogCaptureSettings()))
    }
}
