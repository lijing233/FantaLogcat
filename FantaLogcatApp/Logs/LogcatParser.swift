import Foundation

actor LogcatParser {
    private struct PendingEvent {
        let id: UInt64
        let deviceTimestamp: Date?
        let receivedAt: Date
        let pid: Int32?
        let tid: Int32?
        let priority: LogPriority
        let androidTag: String?
        let businessTag: String?
        var message: String
        var rawText: String
        let parseStatus: LogParseStatus

        var event: LogEvent {
            LogEvent(
                id: id,
                deviceTimestamp: deviceTimestamp,
                receivedAt: receivedAt,
                pid: pid,
                tid: tid,
                priority: priority,
                androidTag: androidTag,
                businessTag: businessTag,
                message: message,
                rawText: rawText,
                parseStatus: parseStatus,
                packageName: nil,
                processName: nil
            )
        }
    }

    private static let headerPattern = #"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*:\s?(.*)$"#

    private let calendar: Calendar
    private let headerExpression: NSRegularExpression
    private var byteRemainder = Data()
    private var nextID: UInt64 = 1
    private var pending: PendingEvent?

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        headerExpression = try! NSRegularExpression(pattern: Self.headerPattern)
    }

    func consume(_ data: Data, receivedAt: Date) -> [LogEvent] {
        byteRemainder.append(data)
        var emitted: [LogEvent] = []

        while let newlineIndex = byteRemainder.firstIndex(of: 0x0A) {
            var lineData = Data(byteRemainder[..<newlineIndex])
            byteRemainder.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            process(String(decoding: lineData, as: UTF8.self), receivedAt: receivedAt, into: &emitted)
        }

        return emitted
    }

    func finish(receivedAt: Date) -> [LogEvent] {
        var emitted: [LogEvent] = []
        if !byteRemainder.isEmpty {
            var lineData = byteRemainder
            byteRemainder.removeAll(keepingCapacity: true)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            process(String(decoding: lineData, as: UTF8.self), receivedAt: receivedAt, into: &emitted)
        }
        if let pending {
            emitted.append(pending.event)
            self.pending = nil
        }
        return emitted
    }

    private func process(_ line: String, receivedAt: Date, into emitted: inout [LogEvent]) {
        if let parsed = parseHeader(line, receivedAt: receivedAt) {
            if let pending {
                emitted.append(pending.event)
            }
            pending = parsed
            nextID += 1
            return
        }

        if pending == nil {
            pending = PendingEvent(
                id: nextID,
                deviceTimestamp: nil,
                receivedAt: receivedAt,
                pid: nil,
                tid: nil,
                priority: .unknown,
                androidTag: nil,
                businessTag: nil,
                message: line,
                rawText: line,
                parseStatus: .raw
            )
            nextID += 1
        } else {
            pending?.message += "\n" + line
            pending?.rawText += "\n" + line
        }
    }

    private func parseHeader(_ line: String, receivedAt: Date) -> PendingEvent? {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = headerExpression.firstMatch(in: line, range: fullRange) else {
            return nil
        }

        func capture(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: line) else { return "" }
            return String(line[range])
        }

        let message = capture(11)
        let trimmedTag = capture(10).trimmingCharacters(in: .whitespaces)
        return PendingEvent(
            id: nextID,
            deviceTimestamp: timestamp(
                month: Int(capture(1))!,
                day: Int(capture(2))!,
                hour: Int(capture(3))!,
                minute: Int(capture(4))!,
                second: Int(capture(5))!,
                millisecond: Int(capture(6))!,
                receivedAt: receivedAt
            ),
            receivedAt: receivedAt,
            pid: Int32(capture(7)),
            tid: Int32(capture(8)),
            priority: priority(for: capture(9)),
            androidTag: trimmedTag.isEmpty ? nil : trimmedTag,
            businessTag: businessTag(in: message),
            message: message,
            rawText: line,
            parseStatus: .complete
        )
    }

    private func timestamp(
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        millisecond: Int,
        receivedAt: Date
    ) -> Date? {
        let receivedYear = calendar.component(.year, from: receivedAt)
        return [receivedYear - 1, receivedYear, receivedYear + 1]
            .compactMap { year in
                calendar.date(from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    second: second,
                    nanosecond: millisecond * 1_000_000
                ))
            }
            .min { abs($0.timeIntervalSince(receivedAt)) < abs($1.timeIntervalSince(receivedAt)) }
    }

    private func priority(for marker: String) -> LogPriority {
        switch marker {
        case "V": .verbose
        case "D": .debug
        case "I": .info
        case "W": .warning
        case "E": .error
        case "F": .fatal
        default: .unknown
        }
    }

    private func businessTag(in message: String) -> String? {
        guard message.first == "[", let closing = message.firstIndex(of: "]") else {
            return nil
        }
        let start = message.index(after: message.startIndex)
        guard start < closing else { return nil }
        return String(message[start..<closing])
    }
}
