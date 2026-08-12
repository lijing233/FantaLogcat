import Foundation

struct LogSearchHighlightSegment: Sendable, Equatable {
    let text: String
    let isMatch: Bool
}

enum LogSearchHighlighting {
    static func segments(in text: String, matching query: String) -> [LogSearchHighlightSegment] {
        segments(in: text, matching: [query])
    }

    static func segments(in text: String, matching queries: [String]) -> [LogSearchHighlightSegment] {
        let terms = queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return [LogSearchHighlightSegment(text: text, isMatch: false)]
        }

        var segments: [LogSearchHighlightSegment] = []
        var cursor = text.startIndex
        while let range = firstMatch(in: text, terms: terms, from: cursor) {
            if cursor < range.lowerBound {
                segments.append(LogSearchHighlightSegment(text: String(text[cursor..<range.lowerBound]), isMatch: false))
            }
            segments.append(LogSearchHighlightSegment(text: String(text[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(LogSearchHighlightSegment(text: String(text[cursor...]), isMatch: false))
        }
        return segments.isEmpty ? [LogSearchHighlightSegment(text: text, isMatch: false)] : segments
    }

    private static func firstMatch(in text: String, terms: [String], from index: String.Index) -> Range<String.Index>? {
        terms
            .compactMap { text.range(of: $0, options: .caseInsensitive, range: index..<text.endIndex) }
            .min { left, right in
                if left.lowerBound == right.lowerBound {
                    return text.distance(from: left.lowerBound, to: left.upperBound) > text.distance(from: right.lowerBound, to: right.upperBound)
                }
                return left.lowerBound < right.lowerBound
            }
    }
}

struct LogFilter: Sendable, Equatable {
    var levels: Set<LogPriority>
    var keyword: String

    init(levels: Set<LogPriority> = [], keyword: String = "") {
        self.levels = levels
        self.keyword = keyword
    }

    var highlightTerms: [String] {
        keywordGroups(for: keyword.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 }
    }

    func apply(_ events: [LogEvent]) -> [LogEvent] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            let matchesLevel = levels.isEmpty || levels.contains(event.priority)
            guard matchesLevel else { return false }
            guard !query.isEmpty else { return true }
            let searchableText = searchableText(for: event)
            return keywordGroups(for: query).contains { group in
                group.allSatisfy(searchableText.localizedCaseInsensitiveContains)
            }
        }
    }

    private func searchableText(for event: LogEvent) -> String {
        [event.message, event.androidTag, event.businessTag]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func keywordGroups(for query: String) -> [[String]] {
        let normalizedOr = replacingMatches(
            in: query,
            pattern: #"\s*(?:\||\bOR\b|或)\s*"#,
            with: "|"
        )
        return normalizedOr.split(separator: "|").compactMap { group in
            let normalizedAnd = replacingMatches(
                in: String(group),
                pattern: #"\s*(?:\+|\bAND\b|并且|且)\s*"#,
                with: "+"
            )
            let terms = normalizedAnd
                .split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return terms.isEmpty ? nil : terms
        }
    }

    private func replacingMatches(in value: String, pattern: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}
