import Foundation

struct SavedKeyword: Codable, Equatable, Identifiable, Sendable {
    let value: String

    var id: String { value.localizedLowercase }
}

protocol LogKeywordStoreProtocol: Sendable {
    var keywords: [SavedKeyword] { get }
    func save(_ keyword: String)
    func remove(_ keyword: String)
}

final class UserDefaultsLogKeywordStore: LogKeywordStoreProtocol, @unchecked Sendable {
    static let storageKey = "io.github.fantalogcat.log-keywords.v1"
    private static let maximumKeywordCount = 6

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var keywords: [SavedKeyword] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? decoder.decode([SavedKeyword].self, from: data) else {
            return []
        }
        return decoded
    }

    func save(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = keywords
        updated.removeAll { $0.value.localizedCaseInsensitiveCompare(value) == .orderedSame }
        updated.insert(SavedKeyword(value: value), at: 0)
        save(Array(updated.prefix(Self.maximumKeywordCount)))
    }

    func remove(_ keyword: String) {
        var updated = keywords
        updated.removeAll { $0.value.localizedCaseInsensitiveCompare(keyword) == .orderedSame }
        save(updated)
    }

    private func save(_ keywords: [SavedKeyword]) {
        guard let data = try? encoder.encode(keywords) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
