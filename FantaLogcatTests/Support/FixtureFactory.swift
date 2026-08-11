import Foundation
@testable import FantaLogcat

enum FixtureFactory {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static let referenceDate = utcCalendar.date(
        from: DateComponents(
            year: 2026,
            month: 8,
            day: 11,
            hour: 12,
            minute: 0,
            second: 1
        )
    )!
}

extension LogEvent {
    static func fixture(
        id: UInt64,
        pid: Int32? = nil,
        tid: Int32? = nil,
        priority: LogPriority = .info,
        androidTag: String? = nil,
        businessTag: String? = nil,
        message: String = "message",
        rawText: String? = nil,
        parseStatus: LogParseStatus = .complete,
        deviceTimestamp: Date? = nil,
        receivedAt: Date = FixtureFactory.referenceDate,
        packageName: String? = nil,
        processName: String? = nil
    ) -> LogEvent {
        LogEvent(
            id: id,
            deviceTimestamp: deviceTimestamp ?? FixtureFactory.utcCalendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 11,
                    hour: 12,
                    minute: 0,
                    second: 0,
                    nanosecond: 123_000_000
                )
            ),
            receivedAt: receivedAt,
            pid: pid,
            tid: tid,
            priority: priority,
            androidTag: androidTag,
            businessTag: businessTag,
            message: message,
            rawText: rawText ?? message,
            parseStatus: parseStatus,
            packageName: packageName,
            processName: processName
        )
    }
}
