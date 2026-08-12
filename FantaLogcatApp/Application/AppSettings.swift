import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let storageKey = "io.github.fantalogcat.app-settings.v1"

    var language: AppLanguage
    var capture: LogCaptureSettings

    var normalized: AppSettings {
        AppSettings(language: language, capture: capture.normalized)
    }
}

protocol AppSettingsStore: Sendable {
    var settings: AppSettings { get }
    func save(_ settings: AppSettings) throws
}

final class UserDefaultsAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: AppSettings {
        if let data = defaults.data(forKey: AppSettings.storageKey),
           let value = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return value.normalized
        }

        let language = AppLanguage(
            rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? ""
        ) ?? .chinese
        let capture = defaults.data(forKey: LogCaptureSettings.storageKey)
            .flatMap { try? JSONDecoder().decode(LogCaptureSettings.self, from: $0) }
            ?? LogCaptureSettings()
        let migrated = AppSettings(language: language, capture: capture).normalized
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: AppSettings.storageKey)
        }
        return migrated
    }

    func save(_ settings: AppSettings) throws {
        let value = settings.normalized
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: AppSettings.storageKey)
    }
}
