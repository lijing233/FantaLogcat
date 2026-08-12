import XCTest
@testable import FantaLogcat

final class LogFilteringTests: XCTestCase {
    private let events: [LogEvent] = [
        .fixture(id: 1, priority: .info, androidTag: "Unity", message: "network ready"),
        .fixture(id: 2, priority: .warning, androidTag: "SDK", message: "Network timed out"),
        .fixture(id: 3, priority: .error, businessTag: "Network", message: "request failed"),
        .fixture(id: 4, priority: .error, androidTag: "Unity", message: "NullReferenceException")
    ]

    func testFilterCombinesSelectedLevelsAndKeywordAcrossMessageAndTags() {
        let filter = LogFilter(levels: [.warning, .error], keyword: "network")

        XCTAssertEqual(filter.apply(events).map(\.id), [2, 3])
    }

    func testEmptyKeywordKeepsSelectedLevelsWithoutTreatingWhitespaceAsAQuery() {
        let filter = LogFilter(levels: [.error], keyword: "   ")

        XCTAssertEqual(filter.apply(events).map(\.id), [3, 4])
    }

    func testEmptyLevelSelectionShowsEveryPriority() {
        let filter = LogFilter(levels: [], keyword: "")

        XCTAssertEqual(filter.apply(events).map(\.id), [1, 2, 3, 4])
    }

    func testSearchHighlightingMarksEveryCaseInsensitiveMatch() {
        let segments = LogSearchHighlighting.segments(in: "Network network", matching: "network")

        XCTAssertEqual(segments.map(\.text), ["Network", " ", "network"])
        XCTAssertEqual(segments.map(\.isMatch), [true, false, true])
    }

    func testKeywordOrReturnsEventsContainingEitherTerm() {
        let filter = LogFilter(keyword: "Withdraw 或 GameEntry")

        XCTAssertEqual(filter.apply([
            .fixture(id: 1, message: "Withdraw opened"),
            .fixture(id: 2, message: "GameEntry started"),
            .fixture(id: 3, message: "Home opened")
        ]).map(\.id), [1, 2])
    }

    func testKeywordAndReturnsOnlyEventsContainingEveryTerm() {
        let filter = LogFilter(keyword: "GameEntry AND Withdraw")

        XCTAssertEqual(filter.apply([
            .fixture(id: 1, message: "GameEntry then Withdraw"),
            .fixture(id: 2, message: "GameEntry started"),
            .fixture(id: 3, message: "Withdraw opened")
        ]).map(\.id), [1])
    }
}
