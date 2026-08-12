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
