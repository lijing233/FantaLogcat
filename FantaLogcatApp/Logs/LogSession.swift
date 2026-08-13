import Foundation

protocol LogSessionProtocol: Sendable {
    func recentEvents(
        on device: DeviceDescriptor,
        pids: [Int32],
        limit: Int
    ) async throws -> [LogEvent]

    func events(
        on device: DeviceDescriptor,
        pids: [Int32]
    ) throws -> AsyncThrowingStream<LogEvent, Error>

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error>

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        filter: LogFilter,
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error>
}

extension LogSessionProtocol {
    func recentEvents(
        on device: DeviceDescriptor,
        pids: [Int32],
        limit: Int
    ) async throws -> [LogEvent] {
        []
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        try events(on: device, pids: pids)
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        filter: LogFilter,
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        try events(on: device, pids: pids, startingID: startingID)
    }
}

struct LogSession: LogSessionProtocol, Sendable {
    private static let liveEventIdleFlushDelay = Duration.milliseconds(80)
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    func recentEvents(
        on device: DeviceDescriptor,
        pids: [Int32],
        limit: Int
    ) async throws -> [LogEvent] {
        let result = try await adb.run(
            .logcatSnapshotThreadtime(device.serial, pids: pids, lineCount: limit),
            timeout: .seconds(5)
        )
        let parser = LogcatParser()
        let receivedAt = Date()
        var events = await parser.consume(result.stdout, receivedAt: receivedAt)
        events.append(contentsOf: await parser.finish(receivedAt: receivedAt))
        return events
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32]
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        try events(on: device, pids: pids, startingID: 1)
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        try events(on: device, pids: pids, filter: LogFilter(captureMode: .standard), startingID: startingID)
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32],
        filter: LogFilter,
        startingID: UInt64
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        let command: ADBCommand
        if filter.captureMode == .fast, filter.hasKeyword {
            if let keyword = Self.singleKeyword(in: filter.keywordGroups) {
                command = .logcatThreadtimeGrep(device.serial, pids: pids, keyword: keyword)
            } else {
                command = .logcatThreadtimeFiltered(
                    device.serial,
                    pids: pids,
                    awkProgram: Self.awkProgram(for: filter.keywordGroups)
                )
            }
        } else {
            command = .logcatThreadtime(device.serial, pids: pids)
        }
        let output = try adb.stream(command)
        let pair = AsyncThrowingStream<LogEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8_192)
        )
        let task = Task.detached(priority: .userInitiated) {
            let parser = LogcatParser(initialID: startingID)
            var idleFlushTask: Task<Void, Never>?

            func yield(_ events: [LogEvent]) throws {
                for event in events {
                    guard case .enqueued = pair.continuation.yield(event) else {
                        throw ProcessRunnerError.outputBufferOverflow
                    }
                }
            }

            do {
                for try await item in output {
                    guard case .stdout(let data) = item else { continue }
                    idleFlushTask?.cancel()
                    let parsed = await parser.consume(data, receivedAt: Date())
                    try yield(parsed)

                    idleFlushTask = Task.detached(priority: .userInitiated) {
                        do {
                            try await Task.sleep(for: Self.liveEventIdleFlushDelay)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }

                        let pending = await parser.flushPending()
                        for event in pending {
                            guard case .enqueued = pair.continuation.yield(event) else {
                                pair.continuation.finish(throwing: ProcessRunnerError.outputBufferOverflow)
                                return
                            }
                        }
                    }
                }
                idleFlushTask?.cancel()
                let finalEvents = await parser.finish(receivedAt: Date())
                try yield(finalEvents)
                pair.continuation.finish()
            } catch {
                idleFlushTask?.cancel()
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return pair.stream
    }

    private static func awkProgram(for groups: [[String]]) -> String {
        let clauses = groups.map { group in
            "(" + group.map { "index(tolower($0), \"\(awkString($0.lowercased()))\")" }.joined(separator: " && ") + ")"
        }
        let matches = clauses.joined(separator: " || ")
        return "/^[0-9][0-9]-[0-9][0-9] / { keep = (\(matches)); if (keep) { print; fflush() }; next } keep { print; fflush() }"
    }

    private static func singleKeyword(in groups: [[String]]) -> String? {
        guard groups.count == 1, groups[0].count == 1 else { return nil }
        return groups[0][0]
    }

    private static func awkString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
