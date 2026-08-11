import Foundation
import XCTest
@testable import FantaLogcat

final class LogcatParserTests: XCTestCase {
    func testConsumesSplitUTF8AndMergesStackTrace() async throws {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        let raw = "08-11 12:00:00.123  42  43 E Unity   : [NetworkManager]: 请求失败\n    at Game.Update()"
        let bytes = Data((raw + "\n").utf8)
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xE8)) + 1

        let first = await parser.consume(
            Data(bytes[..<split]),
            receivedAt: FixtureFactory.referenceDate
        )
        let second = await parser.consume(
            Data(bytes[split...]),
            receivedAt: FixtureFactory.referenceDate
        )
        let tail = await parser.finish(receivedAt: FixtureFactory.referenceDate)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second + tail, [
            LogEvent.fixture(
                id: 1,
                pid: 42,
                tid: 43,
                priority: .error,
                androidTag: "Unity",
                businessTag: "NetworkManager",
                message: "[NetworkManager]: 请求失败\n    at Game.Update()",
                rawText: raw
            )
        ])
    }

    func testMalformedLineIsPreserved() async {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)

        _ = await parser.consume(
            Data("not threadtime\n".utf8),
            receivedAt: FixtureFactory.referenceDate
        )
        let events = await parser.finish(receivedAt: FixtureFactory.referenceDate)

        XCTAssertEqual(events.first?.parseStatus, .raw)
        XCTAssertEqual(events.first?.rawText, "not threadtime")
    }

    func testMapsEveryThreadtimePriority() async {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        let cases: [(String, LogPriority)] = [
            ("V", .verbose),
            ("D", .debug),
            ("I", .info),
            ("W", .warning),
            ("E", .error),
            ("F", .fatal)
        ]
        let text = cases
            .map { "08-11 12:00:00.123  42  43 \($0.0) Unity: message" }
            .joined(separator: "\n") + "\n"

        let emitted = await parser.consume(
            Data(text.utf8),
            receivedAt: FixtureFactory.referenceDate
        )
        let tail = await parser.finish(receivedAt: FixtureFactory.referenceDate)

        XCTAssertEqual((emitted + tail).map(\.priority), cases.map(\.1))
    }

    func testInfersPreviousYearForDecemberLogReceivedInJanuary() async throws {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        let receivedAt = try XCTUnwrap(FixtureFactory.utcCalendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 0, minute: 0, second: 1)
        ))
        _ = await parser.consume(
            Data("12-31 23:59:59.999  42  43 I Unity: rollover\n".utf8),
            receivedAt: receivedAt
        )

        let events = await parser.finish(receivedAt: receivedAt)
        let event = try XCTUnwrap(events.first)
        let timestamp = try XCTUnwrap(event.deviceTimestamp)

        XCTAssertEqual(FixtureFactory.utcCalendar.component(.year, from: timestamp), 2025)
        XCTAssertEqual(FixtureFactory.utcCalendar.component(.month, from: timestamp), 12)
    }

    func testNormalizesEmptyAndroidTagToNil() async throws {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        _ = await parser.consume(
            Data("08-11 12:00:00.123  42  43 I     : message\n".utf8),
            receivedAt: FixtureFactory.referenceDate
        )

        let events = await parser.finish(receivedAt: FixtureFactory.referenceDate)
        let event = try XCTUnwrap(events.first)

        XCTAssertNil(event.androidTag)
    }

    func testAllowsColonInsideAndroidTag() async throws {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        _ = await parser.consume(
            Data("08-11 12:00:00.123  42  43 I Unity:Render: ready\n".utf8),
            receivedAt: FixtureFactory.referenceDate
        )

        let events = await parser.finish(receivedAt: FixtureFactory.referenceDate)
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.androidTag, "Unity:Render")
        XCTAssertEqual(event.message, "ready")
    }

    func testInvalidCalendarDateIsPreservedAsRaw() async throws {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
        let raw = "02-31 12:00:00.123  42  43 I Unity: impossible"
        _ = await parser.consume(
            Data((raw + "\n").utf8),
            receivedAt: FixtureFactory.referenceDate
        )

        let events = await parser.finish(receivedAt: FixtureFactory.referenceDate)
        let event = try XCTUnwrap(events.first)

        XCTAssertEqual(event.parseStatus, .raw)
        XCTAssertNil(event.deviceTimestamp)
        XCTAssertEqual(event.rawText, raw)
    }

    func testEmitsBoundedPartialEventForLineWithoutNewline() async {
        let parser = LogcatParser(calendar: FixtureFactory.utcCalendar, maxLineBytes: 16)
        let emitted = await parser.consume(
            Data(repeating: 0x41, count: 17),
            receivedAt: FixtureFactory.referenceDate
        )
        let tail = await parser.finish(receivedAt: FixtureFactory.referenceDate)

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.parseStatus, .partial)
        XCTAssertEqual(emitted.first?.rawText.utf8.count, 16)
        XCTAssertEqual((emitted + tail).map(\.rawText).joined(), String(repeating: "A", count: 17))
    }
}
