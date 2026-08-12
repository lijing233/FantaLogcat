import Foundation
import XCTest
@testable import FantaLogcat

final class LogKeywordStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FantaLogcatTests.LogKeywordStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSavingKeywordDeduplicatesAndMovesItToTheFront() {
        let store = UserDefaultsLogKeywordStore(defaults: defaults)

        store.save("Unity")
        store.save("Exception")
        store.save("Unity")

        XCTAssertEqual(store.keywords.map(\.value), ["Unity", "Exception"])
    }

    func testSavingKeywordsTrimsEmptyValuesAndKeepsAtMostSix() {
        let store = UserDefaultsLogKeywordStore(defaults: defaults)
        store.save("   ")
        (1...7).forEach { store.save("keyword\($0)") }

        XCTAssertEqual(store.keywords.map(\.value), ["keyword7", "keyword6", "keyword5", "keyword4", "keyword3", "keyword2"])
    }

    func testRemovingSavedKeywordPersists() {
        let store = UserDefaultsLogKeywordStore(defaults: defaults)
        store.save("Unity")
        store.remove("Unity")

        XCTAssertTrue(store.keywords.isEmpty)
    }
}
