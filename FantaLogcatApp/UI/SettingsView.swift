import SwiftUI

struct SettingsView: View {
    private enum Section: CaseIterable, Identifiable {
        case general
        case logs
        case updates
        case about

        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateController: UpdateController
    @State private var draft: AppSettings
    @State private var selectedSection: Section = .general
    @State private var saveErrorMessage: String?
    private let onClose: () -> Void

    init(initialDraft: AppSettings, onClose: @escaping () -> Void) {
        _draft = State(initialValue: initialDraft)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                sidebar
                Divider()
                ScrollView {
                    sectionContent
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(32)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft) { _ in
            persistDraft()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Label(copy("返回", "Back"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("settings.close")
            .help(copy("关闭设置", "Close settings"))

            Text(copy("Settings"))
                .font(.title2.weight(.bold))

            Spacer()
            Text(copy("更改会立即生效", "Changes apply immediately"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Section.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(sectionTitle(section), systemImage: sectionIcon(section))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    selectedSection == section ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .accessibilityIdentifier("settings.section.\(section.id)")
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 184, alignment: .leading)
    }

    @ViewBuilder
    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch selectedSection {
            case .general:
                generalSection
            case .logs:
                logsSection
            case .updates:
                updatesSection
            case .about:
                aboutSection
            }

            if let saveErrorMessage {
                Label(saveErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.saveError")
            }
        }
    }

    private var generalSection: some View {
        Group {
            sectionTitle(copy("通用", "General"), subtitle: copy("在这台 Mac 上个性化 FantaLogcat。", "Personalize FantaLogcat for this Mac."))

            settingGroup(copy("Interface language")) {
                Picker(copy("Interface language"), selection: $draft.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language == .chinese ? copy("Simplified Chinese") : copy("English"))
                            .tag(language)
                            .accessibilityIdentifier("settings.language.\(language.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.language")
                .accessibilityValue(draft.language.rawValue)

                Text(copy("Chinese is the default. This preference stays on this Mac."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            settingGroup(copy("Appearance")) {
                Picker(copy("Appearance"), selection: $draft.appearance) {
                    Text(copy("System")).tag(AppAppearance.system)
                    Text(copy("Light")).tag(AppAppearance.light)
                    Text(copy("Dark")).tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.appearance")
                .accessibilityValue(draft.appearance.rawValue)

                Text(copy("Choose a fixed appearance or follow the system setting."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            settingGroup(copy("Default page after connecting a device")) {
                Picker(copy("Default page after connecting a device"), selection: $draft.defaultDeviceDestination) {
                    Text(copy("Choose app and view logs")).tag(DefaultDeviceDestination.logs)
                    Text(copy("Toolbox")).tag(DefaultDeviceDestination.toolbox)
                }
                .pickerStyle(.segmented)

                Text(copy("This preference is used the next time a device is connected or selected."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logsSection: some View {
        Group {
            sectionTitle(copy("Logs and export"), subtitle: copy("这些限制会在下次选择应用时生效。", "These limits apply when you next select an app."))
            settingGroup(copy("会话限制", "Session limits")) {
                Stepper(copy("Read \(draft.capture.historyLines) recent logs when opening an app"), value: binding(\.historyLines), in: 0...LogCaptureSettings.maximumHistoryLines, step: 100)
                Stepper(copy("Keep up to \(draft.capture.maxEvents.formatted()) logs per new session"), value: binding(\.maxEvents), in: 1_000...LogCaptureSettings.maximumEvents, step: 1_000)
                Stepper(copy("Text cache limit \(draft.capture.maxTextBytes / 1_024 / 1_024) MB per new session"), value: binding(\.maxTextBytes), in: 8 * 1_024 * 1_024...LogCaptureSettings.maximumTextBytes, step: 8 * 1_024 * 1_024)
            }
            settingGroup(copy("导出", "Export")) {
                Toggle(copy("Redact exports by default"), isOn: binding(\.redactExportsByDefault))
                    .accessibilityIdentifier("settings.capture.redactExports.\(draft.capture.redactExportsByDefault)")
                Text(copy("Settings apply when you next select an app. Safety ceilings are 500 history lines, 100,000 logs, and 64 MB text cache."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var updatesSection: some View {
        Group {
            sectionTitle(copy("Updates"), subtitle: copy("让 FantaLogcat 保持为最新版本。", "Keep FantaLogcat up to date with the latest release."))
            settingGroup(copy("软件更新", "Software updates")) {
                Toggle(copy("Automatically check for updates"), isOn: Binding(get: { updateController.automaticallyChecksForUpdates }, set: { updateController.automaticallyChecksForUpdates = $0 }))
                Toggle(copy("Automatically download updates"), isOn: Binding(get: { updateController.automaticallyDownloadsUpdates }, set: { updateController.automaticallyDownloadsUpdates = $0 }))
                    .disabled(!updateController.automaticallyChecksForUpdates)
                HStack {
                    Text(copy("Update preferences take effect immediately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(copy("Check for Updates…")) { updateController.checkForUpdates() }
                        .buttonStyle(.bordered)
                        .disabled(!updateController.canCheckForUpdates)
                }
            }
        }
    }

    private var aboutSection: some View {
        Group {
            sectionTitle(copy("About FantaLogcat"), subtitle: copy("原生 macOS Android 调试工作台。", "Native macOS Android debugging workspace."))
            settingGroup(copy("FantaLogcat")) {
                HStack(spacing: 14) {
                    Image("FantaMascot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 46)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy("FantaLogcat"))
                            .font(.headline)
                        Text(copy("Version \(AppVersion.displayString)"))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.appVersion")
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
        .padding(20)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sectionTitle(_ section: Section) -> String {
        switch section {
        case .general: copy("通用", "General")
        case .logs: copy("Logs and export")
        case .updates: copy("Updates")
        case .about: copy("关于", "About")
        }
    }

    private func sectionIcon(_ section: Section) -> String {
        switch section {
        case .general: "slider.horizontal.3"
        case .logs: "doc.text"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LogCaptureSettings, Value>) -> Binding<Value> {
        Binding(
            get: { draft.capture[keyPath: keyPath] },
            set: { draft.capture[keyPath: keyPath] = $0 }
        )
    }

    private func copy(_ resource: LocalizedStringResource) -> String {
        var localizedResource = resource
        localizedResource.locale = Locale(identifier: draft.language.localeIdentifier)
        return String(localized: localizedResource)
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        draft.language == .chinese ? chinese : english
    }

    private func close() {
        onClose()
    }

    private func persistDraft() {
        do {
            try model.saveSettings(draft)
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = draft.language == .chinese
                ? "设置保存失败，请重试。"
                : "Could not save settings. Try again."
        }
    }
}
