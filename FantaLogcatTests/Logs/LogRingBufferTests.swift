import Foundation
import XCTest
@testable import FantaLogcat

final class LogRingBufferTests: XCTestCase {
    func testEvictsOldestEventAtCountLimit() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 2, maxTextBytes: 100))

        let report = await buffer.append([
            .fixture(id: 1, message: "1234"),
            .fixture(id: 2, message: "5678"),
            .fixture(id: 3, message: "90AB")
        ])
        let snapshot = await buffer.snapshot(.all)

        XCTAssertEqual(snapshot.events.map(\.id), [2, 3])
        XCTAssertEqual(report.evictedEvents, 1)
        XCTAssertEqual(report.evictedTextBytes, 8)
        XCTAssertEqual(snapshot.totalEvictedEvents, 1)
    }

    func testEvictsOldestEventAtByteLimit() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 10, maxTextBytes: 16))

        let report = await buffer.append([
            .fixture(id: 1, message: "1234"),
            .fixture(id: 2, message: "5678"),
            .fixture(id: 3, message: "90AB")
        ])
        let snapshot = await buffer.snapshot(.all)

        XCTAssertEqual(snapshot.events.map(\.id), [2, 3])
        XCTAssertEqual(report.evictedEvents, 1)
        XCTAssertEqual(report.evictedTextBytes, 8)
    }

    func testRetainsNewestEventWhenItAloneExceedsByteLimit() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 10, maxTextBytes: 8))

        let report = await buffer.append([
            .fixture(id: 1, message: "12"),
            .fixture(id: 2, message: "12345")
        ])
        let snapshot = await buffer.snapshot(.all)

        XCTAssertEqual(snapshot.events.map(\.id), [2])
        XCTAssertEqual(report.evictedEvents, 1)
        XCTAssertTrue(report.newestEventExceedsByteLimit)
        XCTAssertTrue(snapshot.newestEventExceedsByteLimit)
    }

    func testSnapshotsRemainStableAfterLaterAppends() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 10, maxTextBytes: 1_000))
        _ = await buffer.append([.fixture(id: 1), .fixture(id: 2)])
        let earlier = await buffer.snapshot(.all)

        _ = await buffer.append([.fixture(id: 3)])
        let later = await buffer.snapshot(.all)

        XCTAssertEqual(earlier.events.map(\.id), [1, 2])
        XCTAssertEqual(later.events.map(\.id), [1, 2, 3])
    }

    func testSelectsByIDsAndInclusiveReceivedTime() async {
        let start = FixtureFactory.referenceDate
        let end = start.addingTimeInterval(2)
        let buffer = LogRingBuffer(limits: .default)
        _ = await buffer.append([
            .fixture(id: 1, receivedAt: start),
            .fixture(id: 2, receivedAt: start.addingTimeInterval(1)),
            .fixture(id: 3, receivedAt: end)
        ])

        let byIDs = await buffer.snapshot(.ids([1, 3]))
        let byTime = await buffer.snapshot(.receivedTime(start.addingTimeInterval(1)...end))

        XCTAssertEqual(byIDs.events.map(\.id), [1, 3])
        XCTAssertEqual(byTime.events.map(\.id), [2, 3])
    }

    func testClearResetsEventsAndEvictionAccounting() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 1, maxTextBytes: 100))
        _ = await buffer.append([.fixture(id: 1), .fixture(id: 2)])

        await buffer.clear()
        let snapshot = await buffer.snapshot(.all)

        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.totalEvictedEvents, 0)
        XCTAssertFalse(snapshot.newestEventExceedsByteLimit)
    }

    func testSustainedEvictionPreservesNewestOrderAcrossCompaction() async {
        let buffer = LogRingBuffer(limits: .init(maxEvents: 2, maxTextBytes: 1_000_000))
        let events = (1...5_000).map { LogEvent.fixture(id: UInt64($0), message: "x") }

        let report = await buffer.append(events)
        let snapshot = await buffer.snapshot(.all)

        XCTAssertEqual(snapshot.events.map(\.id), [4_999, 5_000])
        XCTAssertEqual(report.evictedEvents, 4_998)
        XCTAssertEqual(snapshot.totalEvictedEvents, 4_998)
    }
}
