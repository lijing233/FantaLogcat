import Foundation

struct AppSelectionPreferences: Codable, Equatable, Sendable {
    var favoritePackageNames: [String]
    var recentPackageNames: [String]

    static let empty = AppSelectionPreferences(favoritePackageNames: [], recentPackageNames: [])
}

protocol AppSelectionStoreProtocol: Sendable {
    var preferences: AppSelectionPreferences { get }

    @discardableResult
    func toggleFavorite(_ packageName: String) -> Bool
    func recordRecent(_ packageName: String)
}

final class UserDefaultsAppSelectionStore: AppSelectionStoreProtocol, @unchecked Sendable {
    static let storageKey = "io.github.fantalogcat.app-selection-preferences.v1"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var preferences: AppSelectionPreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              let preferences = try? decoder.decode(AppSelectionPreferences.self, from: data) else {
            return .empty
        }
        return preferences
    }

    @discardableResult
    func toggleFavorite(_ packageName: String) -> Bool {
        var updated = preferences
        if let index = updated.favoritePackageNames.firstIndex(of: packageName) {
            updated.favoritePackageNames.remove(at: index)
            save(updated)
            return false
        }
        updated.favoritePackageNames.append(packageName)
        save(updated)
        return true
    }

    func recordRecent(_ packageName: String) {
        var updated = preferences
        updated.recentPackageNames.removeAll { $0 == packageName }
        updated.recentPackageNames.insert(packageName, at: 0)
        updated.recentPackageNames = Array(updated.recentPackageNames.prefix(6))
        save(updated)
    }

    private func save(_ preferences: AppSelectionPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
