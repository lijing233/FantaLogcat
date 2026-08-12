import XCTest
@testable import FantaLogcat

final class AppSelectionPresentationTests: XCTestCase {
    func testSearchMatchesDisplayNameAndPackageName() throws {
        let tile = try app("com.game.tile", name: "Tile Match")
        let utility = try app("com.example.utility", name: "Utility")

        XCTAssertEqual(
            AppSelectionPresentation.searchResults([tile, utility], query: "com.game"),
            [tile]
        )
        XCTAssertEqual(
            AppSelectionPresentation.searchResults([tile, utility], query: "utility"),
            [utility]
        )
    }

    func testOtherAppsExcludesRecentAndFavoriteApps() throws {
        let tile = try app("com.game.tile", name: "Tile Match")
        let other = try app("com.other.app", name: "Other")
        let third = try app("com.third.app", name: "Third")

        XCTAssertEqual(
            AppSelectionPresentation.otherApps([tile, other, third], recent: [tile], favorites: [other]),
            [third]
        )
    }

    private func app(_ packageName: String, name: String) throws -> AppDescriptor {
        AppDescriptor(
            packageName: try AndroidPackageName(packageName),
            presentation: AppPresentation(displayName: name, symbolName: nil, provenance: .generic)
        )
    }
}
