import Foundation

enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum DefaultDeviceDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case logs
    case toolbox

    var id: String { rawValue }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let storageKey = "io.github.fantalogcat.app-settings.v1"

    var language: AppLanguage
    var appearance: AppAppearance
    var defaultDeviceDestination: DefaultDeviceDestination
    var capture: LogCaptureSettings

    init(
        language: AppLanguage,
        appearance: AppAppearance = .system,
        defaultDeviceDestination: DefaultDeviceDestination = .logs,
        capture: LogCaptureSettings
    ) {
        self.language = language
        self.appearance = appearance
        self.defaultDeviceDestination = defaultDeviceDestination
        self.capture = capture
    }

    var normalized: AppSettings {
        AppSettings(
            language: language,
            appearance: appearance,
            defaultDeviceDestination: defaultDeviceDestination,
            capture: capture.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case language
        case appearance
        case defaultDeviceDestination
        case capture
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(AppLanguage.self, forKey: .language)
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        defaultDeviceDestination = try container.decodeIfPresent(
            DefaultDeviceDestination.self,
            forKey: .defaultDeviceDestination
        ) ?? .logs
        capture = try container.decode(LogCaptureSettings.self, forKey: .capture)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(language, forKey: .language)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(defaultDeviceDestination, forKey: .defaultDeviceDestination)
        try container.encode(capture, forKey: .capture)
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
