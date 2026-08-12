import Foundation

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese
    case english

    static let storageKey = "io.github.fantalogcat.language.v1"

    var id: String { rawValue }
    var localeIdentifier: String { self == .chinese ? "zh-Hans" : "en" }
    var displayName: String { self == .chinese ? "简体中文" : "English" }
}
