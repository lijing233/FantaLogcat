import Foundation

enum KeywordOperator: String, CaseIterable, Sendable {
    case or = "OR"
    case and = "AND"
}

struct SelectedKeyword: Identifiable, Equatable, Sendable {
    let id: UUID
    let value: String
    var relation: KeywordOperator?

    init(id: UUID = UUID(), value: String, relation: KeywordOperator?) {
        self.id = id
        self.value = value
        self.relation = relation
    }
}

struct LogSearchBuilder: Equatable, Sendable {
    var draft: String
    var keywords: [SelectedKeyword]
    var nextOperator: KeywordOperator

    init(
        draft: String = "",
        keywords: [SelectedKeyword] = [],
        nextOperator: KeywordOperator = .or
    ) {
        self.draft = draft
        self.keywords = keywords
        self.nextOperator = nextOperator
        normalizeKeywordOperators()
    }

    init?(restoringFlatQuery query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let expression = try? NSRegularExpression(
            pattern: #"\s+(OR|AND)\s+"#,
            options: [.caseInsensitive]
        )
        guard let expression else { return nil }
        let fullRange = NSRange(value.startIndex..., in: value)
        let matches = expression.matches(in: value, range: fullRange)
        var restored: [SelectedKeyword] = []
        var cursor = value.startIndex
        var pendingRelation: KeywordOperator?

        for match in matches {
            guard let operatorRange = Range(match.range(at: 1), in: value),
                  let matchRange = Range(match.range, in: value) else { return nil }
            let term = String(value[cursor..<matchRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidRestoredTerm(term) else { return nil }
            restored.append(SelectedKeyword(value: term, relation: restored.isEmpty ? nil : pendingRelation))
            pendingRelation = KeywordOperator(rawValue: String(value[operatorRange]).uppercased())
            cursor = matchRange.upperBound
        }

        let lastTerm = String(value[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidRestoredTerm(lastTerm) else { return nil }
        restored.append(SelectedKeyword(value: lastTerm, relation: restored.isEmpty ? nil : pendingRelation))
        guard restored.count == matches.count + 1,
              restored.dropFirst().allSatisfy({ $0.relation != nil }) else { return nil }

        self.init(keywords: restored, nextOperator: restored.last?.relation ?? .or)
    }

    private static func isValidRestoredTerm(_ term: String) -> Bool {
        let uppercase = term.uppercased()
        return !term.isEmpty
            && uppercase != "OR"
            && uppercase != "AND"
            && !uppercase.hasPrefix("OR ")
            && !uppercase.hasPrefix("AND ")
            && !uppercase.hasSuffix(" OR")
            && !uppercase.hasSuffix(" AND")
    }

    mutating func addDraft() {
        let value = draft
        draft = ""
        addKeyword(value)
    }

    mutating func addKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keywords.append(SelectedKeyword(
            value: trimmed,
            relation: keywords.isEmpty ? nil : nextOperator
        ))
    }

    mutating func remove(id: UUID) {
        keywords.removeAll { $0.id == id }
        normalizeKeywordOperators()
    }

    mutating func clear() {
        self = LogSearchBuilder()
    }

    var query: String {
        keywords.enumerated().map { index, keyword in
            guard index > 0, let relation = keyword.relation else { return keyword.value }
            return "\(relation.rawValue) \(keyword.value)"
        }
        .joined(separator: " ")
    }

    private mutating func normalizeKeywordOperators() {
        guard !keywords.isEmpty else { return }
        keywords[0].relation = nil
        for index in keywords.indices.dropFirst() where keywords[index].relation == nil {
            keywords[index].relation = nextOperator
        }
    }
}
