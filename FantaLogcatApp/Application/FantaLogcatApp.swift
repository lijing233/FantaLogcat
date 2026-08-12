import SwiftUI

@main
struct FantaLogcatApp: App {
    private enum LaunchSurface {
        case production
        case settings
        case search
    }

    private static let uiTestingDefaultsSuite = "io.github.fantalogcat.ui-testing"

    private let launchSurface: LaunchSurface
    @StateObject private var model: AppModel

    init() {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        let surface: LaunchSurface
        if arguments.contains("--ui-testing-settings") {
            surface = .settings
        } else if arguments.contains("--ui-testing-search") {
            surface = .search
        } else {
            surface = .production
        }

        launchSurface = surface

        switch surface {
        case .production:
            _model = StateObject(wrappedValue: AppModel(environment: .production))
        case .settings:
            let defaults = UserDefaults(suiteName: Self.uiTestingDefaultsSuite)!
            if arguments.contains("--ui-testing-reset") {
                Self.resetUITestingPreferences(in: defaults)
            }
            _model = StateObject(wrappedValue: AppModel(
                environment: .test(),
                keywordStore: UITestingLogKeywordStore(),
                settingsStore: UserDefaultsAppSettingsStore(defaults: defaults)
            ))
        case .search:
            _model = StateObject(wrappedValue: AppModel(
                environment: .test(),
                keywordStore: UITestingLogKeywordStore(),
                settingsStore: UITestingAppSettingsStore()
            ))
        }
    }

    var body: some Scene {
        WindowGroup {
            launchContent
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: model.language.localeIdentifier))
        }
    }

    @ViewBuilder
    private var launchContent: some View {
        switch launchSurface {
        case .production:
            RootView()
        case .settings:
            UITestingSettingsHost()
                .frame(minWidth: 560, minHeight: 420)
        case .search:
            UITestingSearchHost()
                .frame(minWidth: 920, minHeight: 240, alignment: .top)
        }
    }

    private static func resetUITestingPreferences(in defaults: UserDefaults) {
        [
            AppLanguage.storageKey,
            LogCaptureSettings.storageKey,
            UserDefaultsLogKeywordStore.storageKey,
            UserDefaultsAppSelectionStore.storageKey
        ].forEach(defaults.removeObject(forKey:))
    }
}

private struct UITestingSettingsHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingSettings = false

    var body: some View {
        Color.clear
            .onAppear { isShowingSettings = true }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(initialDraft: model.settingsDraft)
                    .environmentObject(model)
            }
    }
}

private struct UITestingSearchHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var builder = LogSearchBuilder()

    var body: some View {
        LogSearchEditor(builder: $builder, clearAction: clearFilters)
            .padding(18)
    }

    private func clearFilters() {
        builder.clear()
        model.clearLogFilters()
    }
}

private final class UITestingLogKeywordStore: LogKeywordStoreProtocol, @unchecked Sendable {
    private var storedKeywords: [SavedKeyword] = []

    var keywords: [SavedKeyword] { storedKeywords }

    func save(_ keyword: String) {
        let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        storedKeywords.removeAll { $0.value.localizedCaseInsensitiveCompare(value) == .orderedSame }
        storedKeywords.insert(SavedKeyword(value: value), at: 0)
    }

    func remove(_ keyword: String) {
        storedKeywords.removeAll { $0.value.localizedCaseInsensitiveCompare(keyword) == .orderedSame }
    }
}

private final class UITestingAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private(set) var settings = AppSettings(language: .chinese, capture: LogCaptureSettings())

    func save(_ settings: AppSettings) {
        self.settings = settings.normalized
    }
}
