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
        // Bearer 必须先处理：若先跑 key=value 规则，它会把
        // "Authorization: Bearer" 中的 "Bearer" 当作值吞掉，留下真正的 token。
        // 负向前瞻避免对已替换的 "Bearer <token>" 造成二次脱敏。
        let bearerRedacted = redact(
            text,
            pattern: #"(?i)(bearer)\s+[^\s,;&]+"#,
            template: "$1 <redacted>"
        )
        return redact(
            bearerRedacted,
            pattern: #"(?i)(authorization|token|password|secret|api[_-]?key)\s*([=:])\s*(?!bearer\b)[^\s,;&]+"#,
            template: "$1$2<redacted>"
        )
    }

    private static func redact(_ text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
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
