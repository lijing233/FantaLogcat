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
        var parseStatus: LogParseStatus

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

    private enum HeaderParseResult {
        case valid(PendingEvent)
        case invalid
        case notHeader
    }

    private static let headerPattern = #"^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*:\s(.*)$"#

    private let calendar: Calendar
    private let headerExpression: NSRegularExpression
    private let maxLineBytes: Int
    private let maxEventTextBytes: Int
    private var byteRemainder = Data()
    private var nextID: UInt64 = 1
    private var pending: PendingEvent?

    init(
        calendar: Calendar = .current,
        maxLineBytes: Int = 1_048_576,
        maxEventTextBytes: Int = 64 * 1_024,
        initialID: UInt64 = 1
    ) {
        self.calendar = calendar
        self.maxEventTextBytes = max(4, maxEventTextBytes)
        self.maxLineBytes = min(max(4, maxLineBytes), self.maxEventTextBytes)
        nextID = initialID
        headerExpression = try! NSRegularExpression(pattern: Self.headerPattern)
    }

    func consume(_ data: Data, receivedAt: Date) -> [LogEvent] {
        byteRemainder.append(data)
        var emitted: [LogEvent] = []

        while true {
            if let newlineIndex = byteRemainder.firstIndex(of: 0x0A),
               byteRemainder.distance(from: byteRemainder.startIndex, to: newlineIndex) <= maxLineBytes {
                var lineData = Data(byteRemainder[..<newlineIndex])
                byteRemainder.removeSubrange(...newlineIndex)
                if lineData.last == 0x0D {
                    lineData.removeLast()
                }
                process(String(decoding: lineData, as: UTF8.self), receivedAt: receivedAt, into: &emitted)
                continue
            }

            guard byteRemainder.count > maxLineBytes else { break }
            emitOversizedPrefix(receivedAt: receivedAt, into: &emitted)
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
        switch parseHeader(line, receivedAt: receivedAt) {
        case .valid(let parsed):
            if let pending {
                emitted.append(pending.event)
            }
            pending = parsed
            nextID += 1
            return
        case .invalid:
            if let pending {
                emitted.append(pending.event)
            }
            pending = rawPendingEvent(line, receivedAt: receivedAt)
            nextID += 1
            return
        case .notHeader:
            break
        }

        if pending == nil {
            pending = rawPendingEvent(line, receivedAt: receivedAt)
            nextID += 1
        } else {
            appendContinuation(line, receivedAt: receivedAt, into: &emitted)
        }
    }

    private func appendContinuation(
        _ line: String,
        receivedAt: Date,
        into emitted: inout [LogEvent]
    ) {
        guard var pending else {
            self.pending = rawPendingEvent(line, receivedAt: receivedAt)
            nextID += 1
            return
        }
        let appendedRawTextBytes = pending.rawText.utf8.count + 1 + line.utf8.count
        guard appendedRawTextBytes <= maxEventTextBytes else {
            pending.parseStatus = .partial
            emitted.append(pending.event)
            self.pending = rawPendingEvent(line, receivedAt: receivedAt)
            nextID += 1
            return
        }
        pending.message += "\n" + line
        pending.rawText += "\n" + line
        self.pending = pending
    }

    private func emitOversizedPrefix(receivedAt: Date, into emitted: inout [LogEvent]) {
        var length = min(maxLineBytes, maxEventTextBytes)
        while length > 0 {
            let boundary = byteRemainder.index(byteRemainder.startIndex, offsetBy: length)
            if byteRemainder[boundary] & 0xC0 != 0x80 { break }
            length -= 1
        }
        if length == 0 {
            length = maxLineBytes
        }

        let boundary = byteRemainder.index(byteRemainder.startIndex, offsetBy: length)
        let chunk = Data(byteRemainder[..<boundary])
        byteRemainder.removeSubrange(..<boundary)

        if let pending {
            emitted.append(pending.event)
            self.pending = nil
        }
        emitted.append(LogEvent(
            id: nextID,
            deviceTimestamp: nil,
            receivedAt: receivedAt,
            pid: nil,
            tid: nil,
            priority: .unknown,
            androidTag: nil,
            businessTag: nil,
            message: String(decoding: chunk, as: UTF8.self),
            rawText: String(decoding: chunk, as: UTF8.self),
            parseStatus: .partial,
            packageName: nil,
            processName: nil
        ))
        nextID += 1
    }

    private func rawPendingEvent(_ line: String, receivedAt: Date) -> PendingEvent {
        PendingEvent(
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
    }

    private func parseHeader(_ line: String, receivedAt: Date) -> HeaderParseResult {
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = headerExpression.firstMatch(in: line, range: fullRange) else {
            return .notHeader
        }

        func capture(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: line) else { return "" }
            return String(line[range])
        }

        let message = capture(11)
        let trimmedTag = capture(10).trimmingCharacters(in: .whitespaces)
        guard let deviceTimestamp = timestamp(
            month: Int(capture(1))!,
            day: Int(capture(2))!,
            hour: Int(capture(3))!,
            minute: Int(capture(4))!,
            second: Int(capture(5))!,
            millisecond: Int(capture(6))!,
            receivedAt: receivedAt
        ) else {
            return .invalid
        }
        return .valid(PendingEvent(
            id: nextID,
            deviceTimestamp: deviceTimestamp,
            receivedAt: receivedAt,
            pid: Int32(capture(7)),
            tid: Int32(capture(8)),
            priority: priority(for: capture(9)),
            androidTag: trimmedTag.isEmpty ? nil : trimmedTag,
            businessTag: businessTag(in: message),
            message: message,
            rawText: line,
            parseStatus: .complete
        ))
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
            .compactMap { year -> Date? in
                guard let date = calendar.date(from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute,
                    second: second,
                    nanosecond: millisecond * 1_000_000
                )) else {
                    return nil
                }
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: date
                )
                guard components.year == year,
                      components.month == month,
                      components.day == day,
                      components.hour == hour,
                      components.minute == minute,
                      components.second == second else {
                    return nil
                }
                return date
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
