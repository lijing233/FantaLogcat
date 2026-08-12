import Foundation

enum LogExportScope: String, CaseIterable, Identifiable {
    case filtered
    case allCaptured

    var id: String { rawValue }
}

struct LogExporter {
    static func text(events: [LogEvent], redact: Bool) -> String {
        events.map { event in
            let timestamp = event.deviceTimestamp ?? event.receivedAt
            let time = Self.timestampFormatter.string(from: timestamp)
            let tag = event.androidTag ?? "raw"
            let message = redact ? redactText(event.message) : event.message
            return "\(time) \(event.priority.marker) \(tag): \(message)"
        }
        .joined(separator: "\n")
        .appending("\n")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func redactText(_ text: String) -> String {
        let patterns = [
            #"(?i)(authorization|token|password|secret|api[_-]?key)\\s*([=:])\\s*[^\\s,;&]+"#,
            #"(?i)(bearer)\\s+[^\\s,;&]+"#
        ]
        return patterns.reduce(text) { result, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return result }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return expression.stringByReplacingMatches(in: result, range: range, withTemplate: "$1$2<redacted>")
        }
    }
}

private extension LogPriority {
    var marker: String {
        switch self {
        case .verbose: "V"
        case .debug: "D"
        case .info: "I"
        case .warning: "W"
        case .error: "E"
        case .fatal: "F"
        case .unknown: "?"
        }
    }
}
