import Foundation

struct LogCaptureSettings: Codable, Equatable, Sendable {
    static let storageKey = "io.github.fantalogcat.log-capture-settings.v1"
    static let maximumHistoryLines = 500
    static let maximumEvents = 100_000
    static let maximumTextBytes = 64 * 1_024 * 1_024

    var historyLines: Int = 500
    var maxEvents: Int = 20_000
    var maxTextBytes: Int = 32 * 1_024 * 1_024
    var redactExportsByDefault = true

    var normalized: LogCaptureSettings {
        var value = self
        value.historyLines = min(max(historyLines, 0), Self.maximumHistoryLines)
        value.maxEvents = min(max(maxEvents, 1_000), Self.maximumEvents)
        value.maxTextBytes = min(max(maxTextBytes, 8 * 1_024 * 1_024), Self.maximumTextBytes)
        return value
    }

    var cacheLimits: CacheLimits {
        let value = normalized
        return CacheLimits(maxEvents: value.maxEvents, maxTextBytes: value.maxTextBytes)
    }

    static func load() -> LogCaptureSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LogCaptureSettings.self, from: data) else {
            return .init()
        }
        return decoded.normalized
    }

    func save() {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
