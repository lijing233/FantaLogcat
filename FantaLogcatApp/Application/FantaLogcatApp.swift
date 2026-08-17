import SwiftUI

@main
struct FantaLogcatApp: App {
    private enum LaunchSurface: Equatable {
        case production
        case settings
        case search
    }

    private static let uiTestingDefaultsSuite = "io.github.fantalogcat.ui-testing"

    private let launchSurface: LaunchSurface
    @StateObject private var model: AppModel
    @StateObject private var updateController: UpdateController

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
        _updateController = StateObject(
            wrappedValue: UpdateController(startingUpdater: surface == .production)
        )

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
                .environmentObject(updateController)
                .environment(\.locale, Locale(identifier: model.language.localeIdentifier))
                .preferredColorScheme(model.effectiveAppearance.colorScheme)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
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
            AppSettings.storageKey,
            UserDefaultsLogKeywordStore.storageKey,
            UserDefaultsAppSelectionStore.storageKey,
            UserDefaultsADBShortcutStore.storageKey
        ].forEach(defaults.removeObject(forKey:))
    }
}

private extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

private struct UITestingSettingsHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingSettings = false

    var body: some View {
        VStack(spacing: 12) {
            Text(model.language.rawValue)
                .accessibilityIdentifier("uiTesting.live.language.\(model.language.rawValue)")
            Text(model.captureSettings.redactExportsByDefault ? "true" : "false")
                .accessibilityIdentifier("uiTesting.live.redaction.\(model.captureSettings.redactExportsByDefault)")
            Button("Open Settings") { isShowingSettings = true }
                .accessibilityIdentifier("uiTesting.settings.reopen")
        }
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

    func save(_ settings: AppSettings) throws {
        self.settings = settings.normalized
    }
}
