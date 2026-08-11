import Foundation

enum LogPriority: String, Codable, Sendable, CaseIterable {
    case verbose
    case debug
    case info
    case warning
    case error
    case fatal
    case unknown
}

enum LogParseStatus: String, Codable, Sendable {
    case complete
    case partial
    case raw
}

struct LogEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UInt64
    let deviceTimestamp: Date?
    let receivedAt: Date
    let pid: Int32?
    let tid: Int32?
    let priority: LogPriority
    let androidTag: String?
    let businessTag: String?
    let message: String
    let rawText: String
    let parseStatus: LogParseStatus
    let packageName: String?
    let processName: String?
}
