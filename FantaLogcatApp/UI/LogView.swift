import SwiftUI
import AppKit

struct LogView: View {
    @EnvironmentObject private var model: AppModel
    private let levels = LogPriority.allCases.filter { $0 != .unknown }
    @State private var isShowingExportSheet = false
    @State private var draftKeyword = ""
    @State private var selectedKeywords: [SelectedKeyword] = []
    @State private var nextKeywordOperator: KeywordOperator = .or

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            if let historyError = model.logHistoryError {
                Label(
                    model.copy("未能读取近期日志（\(historyError)），正在继续实时日志。", "Could not read recent logs (\(historyError)); live logging continues."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingExportSheet) {
            LogExportSheet(isPresented: $isShowingExportSheet)
                .environmentObject(model)
        }
        .onAppear(perform: restoreSearchBuilderIfNeeded)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.returnToAppSelection()
            } label: {
                Label(model.copy("应用", "Apps"), systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedApp?.presentation.displayName ?? model.copy("日志", "Logs"))
                    .font(.headline)
                Text(model.selectedApp?.packageName.value ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            captureStatus
            Text("\(model.filteredLogEvents.count) / \(model.logEvents.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                if model.isLogPresentationPaused {
                    Task { await model.resumeLogPresentation() }
                } else {
                    model.pauseLogPresentation()
                }
            } label: {
                Label(
                    model.isLogPresentationPaused ? model.copy("继续", "Resume") : model.copy("暂停", "Pause"),
                    systemImage: model.isLogPresentationPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.bordered)
            Button {
                model.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(model.copy("设置", "Settings"))
            Button(model.copy("清屏", "Clear")) {
                model.clearLogs()
            }
            .disabled(model.logEvents.isEmpty)
            Button {
                isShowingExportSheet = true
            } label: {
                Label(model.copy("导出", "Export"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(model.logEvents.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var captureStatus: some View {
        switch model.logCaptureState {
        case .waitingForAppLaunch:
            Label(model.copy("等待应用启动", "Waiting for app"), systemImage: "hourglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .loadingRecentLogs:
            Label(model.copy("读取最近日志", "Loading recent logs"), systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .followingLiveLogs:
            Label(model.copy("实时跟随", "Following live"), systemImage: "record.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        case .stopped:
            EmptyView()
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                priorityPreset(model.copy("全部日志", "All logs"), levels: [])
                priorityPreset(model.copy("警告及以上", "Warning and above"), levels: [.warning, .error, .fatal])
                priorityPreset(model.copy("错误及以上", "Error and above"), levels: [.error, .fatal])

                ForEach(levels, id: \.self) { level in
                    Button {
                        var selected = model.logFilter.levels
                        if selected.contains(level) {
                            selected.remove(level)
                        } else {
                            selected.insert(level)
                        }
                        model.setLogLevels(selected)
                    } label: {
                        Label(levelLabel(level), systemImage: model.logFilter.levels.contains(level) ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(model.logFilter.levels.contains(level) ? levelColor(level) : nil)
                }
                Spacer()
                if model.isLogPresentationPaused {
                    Label("\(model.pendingLogEventCount) \(model.copy("条新日志", "new"))", systemImage: "pause.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if !selectedKeywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(selectedKeywords.enumerated()), id: \.element.id) { index, keyword in
                                if index > 0, let relation = keyword.relation {
                                    Text(relation.rawValue)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.tint)
                                }
                                keywordChip(keyword)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(model.copy("输入关键词后按回车添加", "Type a keyword and press Return"), text: $draftKeyword)
                        .textFieldStyle(.plain)
                        .onSubmit { addDraftKeyword() }
                    Button {
                        addDraftKeyword()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(trimmedDraftKeyword.isEmpty)
                    .accessibilityLabel(model.copy("添加关键词", "Add keyword"))
                    Button {
                        model.saveKeyword(trimmedDraftKeyword)
                    } label: {
                        Image(systemName: "star")
                    }
                    .buttonStyle(.borderless)
                    .disabled(trimmedDraftKeyword.isEmpty)
                    .accessibilityLabel(model.copy("保存为常用关键词", "Save as favorite keyword"))
                    Button(KeywordOperator.or.rawValue) {
                        nextKeywordOperator = .or
                    }
                    .buttonStyle(.bordered)
                    .tint(nextKeywordOperator == .or ? .accentColor : nil)
                    .disabled(selectedKeywords.isEmpty)
                    Button(KeywordOperator.and.rawValue) {
                        nextKeywordOperator = .and
                    }
                    .buttonStyle(.bordered)
                    .tint(nextKeywordOperator == .and ? .accentColor : nil)
                    .disabled(selectedKeywords.isEmpty)
                    if !selectedKeywords.isEmpty || !trimmedDraftKeyword.isEmpty {
                        Button {
                            selectedKeywords = []
                            draftKeyword = ""
                            model.setLogKeyword("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(model.copy("清除搜索条件", "Clear search conditions"))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(model.copy(
                "点击常用关键词或输入后按回车添加；OR / AND 决定下一个关键词与前一项的关系。",
                "Click a favorite or press Return to add a term. OR / AND sets the relationship to the next term."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if !model.savedKeywords.isEmpty {
                HStack(spacing: 7) {
                    ForEach(model.savedKeywords) { keyword in
                        Button {
                            addKeyword(keyword.value)
                        } label: {
                            Label(keyword.value, systemImage: "plus")
                        }
                            .buttonStyle(.bordered)
                            .contextMenu {
                                Button(model.copy("移除", "Remove")) { model.removeSavedKeyword(keyword) }
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func priorityPreset(_ label: String, levels: Set<LogPriority>) -> some View {
        Button {
            model.setLogLevels(model.logFilter.levels == levels ? [] : levels)
        } label: {
            Label(label, systemImage: model.logFilter.levels == levels ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .tint(model.logFilter.levels == levels ? .accentColor : nil)
    }

    private func keywordChip(_ keyword: SelectedKeyword) -> some View {
        HStack(spacing: 5) {
            Text(keyword.value)
                .lineLimit(1)
            Button {
                selectedKeywords.removeAll { $0.id == keyword.id }
                normalizeKeywordOperators()
                applyKeywordConditions()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.copy("移除关键词 \(keyword.value)", "Remove keyword \(keyword.value)"))
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.tint.opacity(0.14), in: Capsule())
    }

    private var trimmedDraftKeyword: String {
        draftKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addDraftKeyword() {
        addKeyword(trimmedDraftKeyword)
        draftKeyword = ""
    }

    private func addKeyword(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectedKeywords.append(SelectedKeyword(
            value: trimmed,
            relation: selectedKeywords.isEmpty ? nil : nextKeywordOperator
        ))
        applyKeywordConditions()
    }

    private func applyKeywordConditions() {
        let query = selectedKeywords.enumerated().map { index, keyword in
            guard index > 0, let relation = keyword.relation else { return keyword.value }
            return "\(relation.rawValue) \(keyword.value)"
        }
        .joined(separator: " ")
        model.setLogKeyword(query)
    }

    private func normalizeKeywordOperators() {
        guard !selectedKeywords.isEmpty else { return }
        selectedKeywords[0].relation = nil
        for index in selectedKeywords.indices.dropFirst() where selectedKeywords[index].relation == nil {
            selectedKeywords[index].relation = nextKeywordOperator
        }
    }

    private func restoreSearchBuilderIfNeeded() {
        guard selectedKeywords.isEmpty,
              !model.logFilter.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        selectedKeywords = [SelectedKeyword(value: model.logFilter.keyword, relation: nil)]
    }

    @ViewBuilder
    private var content: some View {
        if model.logEvents.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.logStreamError == nil ? "waveform.path.ecg" : "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(model.logStreamError == nil ? Color.secondary : Color.orange)
                Text(emptyTitle)
                    .font(.headline)
                Text(emptyDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredLogEvents.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text(model.copy("没有匹配当前筛选的日志", "No logs match the current filters"))
                    .font(.headline)
                Button(model.copy("清除筛选", "Clear filters")) {
                    model.setLogLevels([])
                    model.setLogKeyword("")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.filteredLogEvents) { event in
                            LogRow(event: event, highlightTerms: model.logFilter.highlightTerms)
                            Divider().opacity(0.45)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                }
                .onAppear { scrollToLatest(proxy) }
                .onChange(of: model.logEvents.count) { _ in
                    guard !model.isLogPresentationPaused else { return }
                    scrollToLatest(proxy)
                }
            }
        }
    }

    private var emptyTitle: String {
        if model.logCaptureState == .waitingForAppLaunch {
            return model.copy("等待所选应用启动", "Waiting for the selected app to start")
        }
        return model.logStreamError == nil ? model.copy("等待日志", "Waiting for logs") : model.copy("日志流已停止", "Log stream stopped")
    }

    private var emptyDescription: String {
        if let error = model.logStreamError {
            return model.copy("ADB 错误：\(error)。请重新连接设备并再次选择应用。", "ADB error: \(error). Reconnect the device and choose the app again.")
        }
        if model.logCaptureState == .waitingForAppLaunch {
            return model.copy("不会显示其他应用的日志。启动所选应用后会自动开始收集。", "Other apps' logs are not shown. Capture starts automatically when the selected app launches.")
        }
        return model.copy("已显示最近日志；继续使用所选 Android 应用，新日志会自动出现。", "Recent logs are shown. Continue using the selected Android app and new Logcat output will appear automatically.")
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }

    private func levelLabel(_ level: LogPriority) -> String {
        switch level {
        case .verbose: model.copy("详细", "Verbose")
        case .debug: model.copy("调试", "Debug")
        case .info: model.copy("信息", "Info")
        case .warning: model.copy("警告", "Warning")
        case .error: model.copy("错误", "Error")
        case .fatal: model.copy("严重错误", "Fatal")
        case .unknown: model.copy("未知", "Unknown")
        }
    }

    private func levelColor(_ level: LogPriority) -> Color {
        switch level {
        case .warning: .orange
        case .error, .fatal: .red
        case .debug: .purple
        case .verbose: .secondary
        default: .accentColor
        }
    }
}

private struct LogExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var scope: LogExportScope = .filtered
    @State private var redact = true
    @State private var exportedFileURL: URL?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.copy("导出日志", "Export logs")).font(.title3.weight(.bold))
            Picker(model.copy("导出范围", "Scope"), selection: $scope) {
                Text(model.copy("当前筛选结果", "Current filtered results")).tag(LogExportScope.filtered)
                Text(model.copy("当前应用全部已收集日志", "All captured logs for this app")).tag(LogExportScope.allCaptured)
            }
            .pickerStyle(.radioGroup)
            Toggle(model.copy("导出前隐藏常见 token、密码和密钥", "Redact common tokens, passwords, and keys"), isOn: $redact)
            if let exportedFileURL {
                Label(model.copy("日志已导出", "Logs exported"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button(model.copy("在 Finder 中显示", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([exportedFileURL])
                    }
                    Spacer()
                    Button(model.copy("完成", "Done")) { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                if saveFailed {
                    Label(model.copy("无法写入文件，请选择其他位置后重试。", "Could not write the file. Choose another location and try again."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button(model.copy("取消", "Cancel")) { isPresented = false }
                    Button(model.copy("选择保存位置", "Choose save location")) { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { redact = model.captureSettings.redactExportsByDefault }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FantaLogcat-\(ISO8601DateFormatter().string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportText(scope: scope, redact: redact).write(to: url, atomically: true, encoding: .utf8)
            exportedFileURL = url
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}

private struct LogRow: View {
    let event: LogEvent
    let highlightTerms: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(priorityMarker)
                .font(.caption.bold().monospaced())
                .foregroundStyle(priorityColor)
                .frame(width: 14)
            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(highlighted(event.androidTag ?? "raw"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(highlighted(event.message))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var priorityMarker: String {
        switch event.priority {
        case .verbose: "V"
        case .debug: "D"
        case .info: "I"
        case .warning: "W"
        case .error: "E"
        case .fatal: "F"
        case .unknown: "?"
        }
    }

    private var priorityColor: Color {
        switch event.priority {
        case .warning: .orange
        case .error, .fatal: .red
        case .debug: .purple
        case .verbose: .secondary
        default: .primary
        }
    }

    private var timeText: String {
        guard let timestamp = event.deviceTimestamp else { return "--:--:--" }
        return timestamp.formatted(date: .omitted, time: .standard)
    }

    private func highlighted(_ text: String) -> AttributedString {
        LogSearchHighlighting.segments(in: text, matching: highlightTerms).reduce(into: AttributedString()) { result, segment in
            var part = AttributedString(segment.text)
            if segment.isMatch {
                part.backgroundColor = .yellow.opacity(0.42)
                part.foregroundColor = .primary
            }
            result.append(part)
        }
    }
}
