import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings

    init(initialDraft: AppSettings) {
        _draft = State(initialValue: initialDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(copy("Settings"))
                .font(.title2.weight(.bold))

            Picker(copy("Interface language"), selection: $draft.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(
                        language == .chinese
                            ? copy("Simplified Chinese")
                            : copy("English")
                    )
                    .tag(language)
                    .accessibilityIdentifier("settings.language.\(language.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.language")
            .accessibilityValue(draft.language.rawValue)
            .help(copy("Preview the settings sheet in this language"))

            Text(copy("Chinese is the default. This preference stays on this Mac."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            Text(copy("Logs and export"))
                .font(.headline)

            Stepper(
                copy("Read \(draft.capture.historyLines) recent logs when opening an app"),
                value: binding(\.historyLines),
                in: 0...LogCaptureSettings.maximumHistoryLines,
                step: 100
            )

            Stepper(
                copy("Keep up to \(draft.capture.maxEvents.formatted()) logs per new session"),
                value: binding(\.maxEvents),
                in: 1_000...LogCaptureSettings.maximumEvents,
                step: 1_000
            )

            Stepper(
                copy("Text cache limit \(draft.capture.maxTextBytes / 1_024 / 1_024) MB per new session"),
                value: binding(\.maxTextBytes),
                in: 8 * 1_024 * 1_024...LogCaptureSettings.maximumTextBytes,
                step: 8 * 1_024 * 1_024
            )

            Toggle(
                copy("Redact exports by default"),
                isOn: binding(\.redactExportsByDefault)
            )

            Text(copy("Settings apply when you next select an app. Safety ceilings are 500 history lines, 100,000 logs, and 64 MB text cache."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(copy("Close"), action: close)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.close")
                    .help(copy("Discard unsaved settings"))

                Button(copy("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.save")
                    .help(copy("Save and apply all settings"))
            }
        }
        .padding(24)
        .frame(width: 500)
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

    private func close() {
        dismiss()
    }

    private func save() {
        model.saveSettings(draft)
        dismiss()
    }
}
