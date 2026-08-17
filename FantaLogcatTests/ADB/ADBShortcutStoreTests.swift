import Foundation
import XCTest
@testable import FantaLogcat

final class ADBShortcutStoreTests: XCTestCase {
    func testStoresActivityAndDeepLinkFavorites() throws {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsADBShortcutStore(defaults: defaults)
        let activity = SavedActivityShortcut(
            name: "Product debugger",
            component: try AndroidActivityComponent(
                "com.example.game/com.foundation.ProductSettingsActivity"
            ),
            note: "Back door"
        )
        let deepLink = SavedDeepLinkShortcut(
            name: "Open campaign",
            deepLink: "mygame://campaign?id=7",
            packageName: try AndroidPackageName("com.example.game")
        )

        try store.save(ADBShortcutCollection(activities: [activity], deepLinks: [deepLink]))

        XCTAssertEqual(store.shortcuts.activities, [activity])
        XCTAssertEqual(store.shortcuts.deepLinks, [deepLink])
    }

    func testCorruptDataFallsBackToEmptyCollection() {
        let suite = #function
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(Data("invalid".utf8), forKey: UserDefaultsADBShortcutStore.storageKey)

        XCTAssertEqual(
            UserDefaultsADBShortcutStore(defaults: defaults).shortcuts,
            ADBShortcutCollection()
        )
    }
}
