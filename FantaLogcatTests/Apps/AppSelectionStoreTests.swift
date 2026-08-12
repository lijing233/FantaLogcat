import Foundation
import XCTest
@testable import FantaLogcat

final class AppSelectionStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FantaLogcatTests.AppSelectionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testToggleFavoritePersistsPackageName() {
        let store = UserDefaultsAppSelectionStore(defaults: defaults)

        XCTAssertTrue(store.toggleFavorite("com.game.tile"))
        XCTAssertEqual(store.preferences.favoritePackageNames, ["com.game.tile"])
        XCTAssertFalse(store.toggleFavorite("com.game.tile"))
        XCTAssertEqual(store.preferences.favoritePackageNames, [])
    }

    func testRecordRecentMovesExistingPackageToFrontAndLimitsSix() {
        let store = UserDefaultsAppSelectionStore(defaults: defaults)
        (1...7).forEach { store.recordRecent("com.game.\($0)") }

        store.recordRecent("com.game.4")

        XCTAssertEqual(
            store.preferences.recentPackageNames,
            ["com.game.4", "com.game.7", "com.game.6", "com.game.5", "com.game.3", "com.game.2"]
        )
    }

    func testInvalidPersistedDataFallsBackToEmptyPreferences() {
        defaults.set(Data("not json".utf8), forKey: UserDefaultsAppSelectionStore.storageKey)

        let store = UserDefaultsAppSelectionStore(defaults: defaults)

        XCTAssertEqual(store.preferences, .empty)
    }
}
