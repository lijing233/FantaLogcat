import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.copy("设置", "Settings"))
                .font(.title2.weight(.bold))

            Picker(model.copy("界面语言", "Interface language"), selection: Binding(
                get: { model.language },
                set: { model.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)

            Text(model.copy(
                "默认使用简体中文；该设置仅保存在本机。",
                "Chinese is the default. This preference stays on this Mac."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)

            Divider()

            Text(model.copy("日志与导出", "Logs and export"))
                .font(.headline)

            Stepper(
                model.copy("进入应用时读取最近 \(model.captureSettings.historyLines) 条日志", "Read \(model.captureSettings.historyLines) recent logs when opening an app"),
                value: binding(\.historyLines),
                in: 0...LogCaptureSettings.maximumHistoryLines,
                step: 100
            )

            Stepper(
                model.copy("单次会话最多保留 \(model.captureSettings.maxEvents.formatted()) 条日志", "Keep up to \(model.captureSettings.maxEvents.formatted()) logs per new session"),
                value: binding(\.maxEvents),
                in: 1_000...LogCaptureSettings.maximumEvents,
                step: 1_000
            )

            Stepper(
                model.copy("单次会话日志文本上限 \(model.captureSettings.maxTextBytes / 1_024 / 1_024) MB", "Text cache limit \(model.captureSettings.maxTextBytes / 1_024 / 1_024) MB per new session"),
                value: binding(\.maxTextBytes),
                in: 8 * 1_024 * 1_024...LogCaptureSettings.maximumTextBytes,
                step: 8 * 1_024 * 1_024
            )

            Toggle(model.copy("导出时默认脱敏", "Redact exports by default"), isOn: binding(\.redactExportsByDefault))

            Text(model.copy("设置会应用到下一次选择应用；为了稳定性，上限固定为 500 条历史、100,000 条日志和 64 MB 文本缓存。", "Settings apply when you next select an app. Safety ceilings are 500 history lines, 100,000 logs, and 64 MB text cache."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(model.copy("完成", "Done")) { model.isShowingSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LogCaptureSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.captureSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.captureSettings
                settings[keyPath: keyPath] = value
                model.setCaptureSettings(settings)
            }
        )
    }
}
