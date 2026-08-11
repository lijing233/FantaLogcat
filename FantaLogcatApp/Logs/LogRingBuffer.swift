import Foundation

struct CacheLimits: Sendable, Equatable {
    static let `default` = CacheLimits(
        maxEvents: 100_000,
        maxTextBytes: 128 * 1_024 * 1_024
    )

    let maxEvents: Int
    let maxTextBytes: Int

    init(maxEvents: Int, maxTextBytes: Int) {
        precondition(maxEvents > 0, "maxEvents must be greater than zero")
        precondition(maxTextBytes >= 0, "maxTextBytes must not be negative")
        self.maxEvents = maxEvents
        self.maxTextBytes = maxTextBytes
    }
}

struct EvictionReport: Sendable, Equatable {
    let evictedEvents: Int
    let evictedTextBytes: Int
    let newestEventExceedsByteLimit: Bool
}

enum SnapshotSelection: Sendable {
    case all
    case ids(Set<UInt64>)
    case receivedTime(ClosedRange<Date>)
}

struct LogSnapshot: Sendable {
    let events: [LogEvent]
    let totalEvictedEvents: Int
    let newestEventExceedsByteLimit: Bool
}

actor LogRingBuffer {
    private let limits: CacheLimits
    private var storage: [LogEvent] = []
    private var firstRetainedIndex = 0
    private var textBytes = 0
    private var totalEvictedEvents = 0

    init(limits: CacheLimits = .default) {
        self.limits = limits
    }

    func append(_ incoming: [LogEvent]) -> EvictionReport {
        storage.append(contentsOf: incoming)
        textBytes += incoming.reduce(into: 0) { total, event in
            total += Self.textBytes(of: event)
        }

        var evictedEvents = 0
        var evictedBytes = 0
        while retainedCount > limits.maxEvents
            || (textBytes > limits.maxTextBytes && retainedCount > 1) {
            let removed = storage[firstRetainedIndex]
            let bytes = Self.textBytes(of: removed)
            firstRetainedIndex += 1
            textBytes -= bytes
            evictedEvents += 1
            evictedBytes += bytes
        }

        totalEvictedEvents += evictedEvents
        compactStorageIfNeeded()
        return EvictionReport(
            evictedEvents: evictedEvents,
            evictedTextBytes: evictedBytes,
            newestEventExceedsByteLimit: isOverByteLimitBecauseNewestEventIsOversized
        )
    }

    func snapshot(_ selection: SnapshotSelection) -> LogSnapshot {
        let retained = Array(storage[firstRetainedIndex...])
        let selected: [LogEvent]
        switch selection {
        case .all:
            selected = retained
        case .ids(let ids):
            selected = retained.filter { ids.contains($0.id) }
        case .receivedTime(let range):
            selected = retained.filter { range.contains($0.receivedAt) }
        }
        return LogSnapshot(
            events: selected,
            totalEvictedEvents: totalEvictedEvents,
            newestEventExceedsByteLimit: isOverByteLimitBecauseNewestEventIsOversized
        )
    }

    func clear() {
        storage.removeAll(keepingCapacity: true)
        firstRetainedIndex = 0
        textBytes = 0
        totalEvictedEvents = 0
    }

    private var retainedCount: Int {
        storage.count - firstRetainedIndex
    }

    private var isOverByteLimitBecauseNewestEventIsOversized: Bool {
        retainedCount == 1 && textBytes > limits.maxTextBytes
    }

    private func compactStorageIfNeeded() {
        guard firstRetainedIndex >= 4_096,
              firstRetainedIndex * 2 >= storage.count else {
            return
        }
        storage = Array(storage[firstRetainedIndex...])
        firstRetainedIndex = 0
    }

    /// Deterministically accounts for UTF-8 text only; Swift object overhead is excluded.
    private static func textBytes(of event: LogEvent) -> Int {
        event.message.utf8.count + event.rawText.utf8.count
    }
}
