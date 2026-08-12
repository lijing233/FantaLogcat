import Foundation

struct AppSettings: Equatable, Sendable {
    var language: AppLanguage
    var capture: LogCaptureSettings

    var normalized: AppSettings {
        AppSettings(language: language, capture: capture.normalized)
    }
}

protocol AppSettingsStore: Sendable {
    var settings: AppSettings { get }
    func save(_ settings: AppSettings)
}

final class UserDefaultsAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: AppSettings {
        let language = AppLanguage(
            rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? ""
        ) ?? .chinese
        let capture = defaults.data(forKey: LogCaptureSettings.storageKey)
            .flatMap { try? JSONDecoder().decode(LogCaptureSettings.self, from: $0) }
            ?? LogCaptureSettings()
        return AppSettings(language: language, capture: capture).normalized
    }

    func save(_ settings: AppSettings) {
        let value = settings.normalized
        defaults.set(value.language.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(try? JSONEncoder().encode(value.capture), forKey: LogCaptureSettings.storageKey)
    }
}
