import Foundation

struct AndroidActivityComponent: Codable, Equatable, Sendable {
    let packageName: AndroidPackageName
    let activityName: String

    init(_ input: String) throws {
        let component = Self.extractComponent(from: input)
        let pieces = component.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let packageName = try? AndroidPackageName(String(pieces[0])),
              Self.isValidActivityName(String(pieces[1])) else {
            throw ADBValidationError.invalidActivityComponent
        }
        self.packageName = packageName
        self.activityName = String(pieces[1])
    }

    var value: String {
        "\(packageName.value)/\(activityName)"
    }

    private static func extractComponent(from input: String) -> String {
        let tokens = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        if let marker = tokens.lastIndex(of: "-n"), tokens.indices.contains(marker + 1) {
            return stripQuotes(tokens[marker + 1])
        }
        return stripQuotes(tokens.last ?? "")
    }

    private static func stripQuotes(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            result.removeFirst()
            result.removeLast()
        }
        return result
    }

    private static func isValidActivityName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else { return false }
        let candidate = value.hasPrefix(".") ? String(value.dropFirst()) : value
        let pattern = #"^[A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#
        return candidate.range(of: pattern, options: .regularExpression) != nil
    }
}

struct SavedActivityShortcut: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var component: AndroidActivityComponent
    var note: String

    init(id: UUID = UUID(), name: String, component: AndroidActivityComponent, note: String = "") {
        self.id = id
        self.name = name
        self.component = component
        self.note = note
    }
}

struct SavedDeepLinkShortcut: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var deepLink: String
    var packageName: AndroidPackageName?
    var note: String

    init(
        id: UUID = UUID(),
        name: String,
        deepLink: String,
        packageName: AndroidPackageName? = nil,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.deepLink = deepLink
        self.packageName = packageName
        self.note = note
    }
}

struct ADBShortcutCollection: Codable, Equatable, Sendable {
    var activities: [SavedActivityShortcut] = []
    var deepLinks: [SavedDeepLinkShortcut] = []
}

protocol ADBShortcutStore: Sendable {
    var shortcuts: ADBShortcutCollection { get }
    func save(_ shortcuts: ADBShortcutCollection) throws
}

final class UserDefaultsADBShortcutStore: ADBShortcutStore, @unchecked Sendable {
    static let storageKey = "io.github.fantalogcat.adb-shortcuts.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shortcuts: ADBShortcutCollection {
        guard let data = defaults.data(forKey: Self.storageKey),
              let value = try? JSONDecoder().decode(ADBShortcutCollection.self, from: data) else {
            return ADBShortcutCollection()
        }
        return value
    }

    func save(_ shortcuts: ADBShortcutCollection) throws {
        defaults.set(try JSONEncoder().encode(shortcuts), forKey: Self.storageKey)
    }
}
