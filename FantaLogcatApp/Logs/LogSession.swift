import Foundation

enum LogSessionError: Error, Equatable {
    case processExitedNonZero(exitCode: Int32, stderrSummary: String)
}

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
}

struct LogSession: LogSessionProtocol, Sendable {
    private static let liveEventIdleFlushDelay = Duration.milliseconds(80)
    private static let maximumCapturedStderrBytes = 4_096
    /// 近期日志按目标进程过滤，而设备端只能按全局行数限量，因此用倍率放大，
    /// 兼顾高噪声设备上仍能取回目标进程的近期日志。
    static let snapshotLineMultiplier = 8
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    func recentEvents(
        on device: DeviceDescriptor,
        pids: [Int32],
        limit: Int
    ) async throws -> [LogEvent] {
        guard limit > 0 else { return [] }
        let lineLimit = limit * Self.snapshotLineMultiplier
        let bounded = try await snapshotEvents(on: device, pids: pids, lineLimit: lineLimit)
        // 已取足目标进程日志，或限量行数未触顶（缓冲区已完整覆盖）时直接返回，
        // 避免在活跃应用 + 高噪声设备上做无谓的全量抓取。
        if bounded.events.count >= limit || bounded.rawLineCount < lineLimit {
            return Array(bounded.events.suffix(limit))
        }
        // 既未取足又触顶：限量可能截断了目标进程更早的日志，回退完整 dump 兜底。
        let full = try await snapshotEvents(on: device, pids: pids, lineLimit: nil)
        return Array(full.events.suffix(limit))
    }

    private func snapshotEvents(
        on device: DeviceDescriptor,
        pids: [Int32],
        lineLimit: Int?
    ) async throws -> (events: [LogEvent], rawLineCount: Int) {
        let result = try await adb.run(
            .logcatSnapshotThreadtime(device.serial, lineLimit: lineLimit),
            timeout: .seconds(5)
        )
        let rawLineCount = result.stdout.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let parser = LogcatParser()
        let receivedAt = Date()
        var parsed = await parser.consume(result.stdout, receivedAt: receivedAt)
        parsed.append(contentsOf: await parser.finish(receivedAt: receivedAt))
        return (Self.filteringByPID(parsed, pids: pids), rawLineCount)
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
        let output = try adb.stream(.logcatThreadtime(device.serial))
        let pair = AsyncThrowingStream<LogEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8_192)
        )
        let task = Task.detached(priority: .userInitiated) {
            let parser = LogcatParser(initialID: startingID)
            var idleFlushTask: Task<Void, Never>?
            var exitCode: Int32?
            var stderrData = Data()

            func yield(_ events: [LogEvent]) throws {
                for event in Self.filteringByPID(events, pids: pids) {
                    guard case .enqueued = pair.continuation.yield(event) else {
                        throw ProcessRunnerError.outputBufferOverflow
                    }
                }
            }

            do {
                for try await item in output {
                    switch item {
                    case .stdout(let data):
                        idleFlushTask?.cancel()
                        let parsed = await parser.consume(data, receivedAt: Date())
                        try yield(parsed)

                        let generation = await parser.currentGeneration()
                        idleFlushTask = Task.detached(priority: .userInitiated) {
                            do {
                                try await Task.sleep(for: Self.liveEventIdleFlushDelay)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled else { return }

                            let pending = await parser.flushPending(since: generation)
                            for event in Self.filteringByPID(pending, pids: pids) {
                                guard case .enqueued = pair.continuation.yield(event) else {
                                    pair.continuation.finish(throwing: ProcessRunnerError.outputBufferOverflow)
                                    return
                                }
                            }
                        }
                    case .stderr(let data):
                        let remaining = Self.maximumCapturedStderrBytes - stderrData.count
                        if remaining > 0 {
                            stderrData.append(data.prefix(remaining))
                        }
                    case .exited(let code):
                        exitCode = code
                    }
                }
                idleFlushTask?.cancel()
                let finalEvents = await parser.finish(receivedAt: Date())
                try yield(finalEvents)
                if let exitCode, exitCode != 0 {
                    let summary = String(decoding: stderrData, as: UTF8.self)
                    pair.continuation.finish(
                        throwing: LogSessionError.processExitedNonZero(
                            exitCode: exitCode,
                            stderrSummary: summary
                        )
                    )
                } else {
                    pair.continuation.finish()
                }
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

    /// Emits events unchanged when no PID scope is requested, otherwise keeps
    /// only events attributed to one of the target processes.
    private static func filteringByPID(_ events: [LogEvent], pids: [Int32]) -> [LogEvent] {
        guard !pids.isEmpty else { return events }
        let pidSet = Set(pids)
        return events.filter { event in
            event.pid.map(pidSet.contains) ?? false
        }
    }
}
