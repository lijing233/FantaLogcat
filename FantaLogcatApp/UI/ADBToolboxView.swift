import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ADBToolboxView: View {
    private enum Tool: Hashable {
        case apk, scrcpy, deepLink, text, screenshot, appControl, activity, clearData, deviceInfo
    }

    private enum TextInputMode: String, CaseIterable {
        case text
        case json
    }

    private struct Feedback {
        let message: String
        let isError: Bool
    }

    @EnvironmentObject private var model: AppModel

    let service: ADBToolService
    let scrcpy: ScrcpyManager
    let device: DeviceDescriptor
    let apps: [AppDescriptor]

    @State private var selectedPackageName = ""
    @State private var installedPackageName = ""
    @State private var installedAppInfo: AndroidAppInfo?
    @State private var didInstallAPK = false
    @State private var apkURL: URL?
    @State private var isChoosingAPK = false
    @State private var apkOptions = APKInstallOptions()
    @State private var deepLink = ""
    @State private var deepLinkSearch = ""
    @State private var isDeepLinkAdvancedExpanded = false
    @State private var deepLinkTargetsApp = false
    @State private var currentActivity: AndroidActivityComponent?
    @State private var activitySearch = ""
    @State private var showsAllActivities = false
    @State private var activityDraft: ActivityShortcutDraft?
    @State private var deepLinkDraft: DeepLinkShortcutDraft?
    @State private var pendingShortcutDeletion: ShortcutDeletion?
    @State private var shortcuts = UserDefaultsADBShortcutStore().shortcuts
    @State private var inputText = ""
    @State private var textInputMode: TextInputMode = .text
    @State private var clipboardContent = ""
    @State private var clipboardMessage: String?
    @State private var isReadingClipboard = false
    @State private var jsonValidationMessage: String?
    @State private var pressEnter = false
    @State private var isConfirmingClearData = false
    @State private var feedback: [Tool: Feedback] = [:]
    @State private var runningTools: Set<Tool> = []
    @State private var scrcpyAvailability: ScrcpyAvailability = .installRequired
    @State private var isScrcpyRunning = false
    @State private var screenshotURL: URL?
    @State private var deviceInfo: AndroidDeviceInfo?

    private let shortcutStore = UserDefaultsADBShortcutStore()

    private static let apkType = UTType(filenameExtension: "apk") ?? .data

    private var selectedPackage: AndroidPackageName? {
        try? AndroidPackageName(selectedPackageName)
    }

    private var installedPackage: AndroidPackageName? {
        try? AndroidPackageName(installedPackageName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 14) {
                    apkCard
                    appControlCard
                    scrcpyCard
                    textCard
                    screenshotCard
                    deepLinkCard
                    deviceInfoCard
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .fileImporter(
            isPresented: $isChoosingAPK,
            allowedContentTypes: [Self.apkType],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                acceptDroppedAPK(urls)
            case .failure:
                setFeedback(.apk, message: copy("无法读取所选文件。", "Could not read the selected file."), isError: true)
            }
        }
        .onChange(of: installedPackageName) { _ in
            loadInstalledAppInfo()
        }
        .sheet(item: $activityDraft) { draft in
            ActivityShortcutEditor(draft: draft) { saved in
                saveActivityShortcut(saved)
            }
            .environmentObject(model)
        }
        .sheet(item: $deepLinkDraft) { draft in
            DeepLinkShortcutEditor(draft: draft, apps: apps) { saved in
                saveDeepLinkShortcut(saved)
            }
            .environmentObject(model)
        }
        .alert(item: $pendingShortcutDeletion) { deletion in
            Alert(
                title: Text(copy("删除收藏？", "Delete favorite?")),
                message: Text(deletion.name),
                primaryButton: .destructive(Text(copy("删除", "Delete"))) {
                    deleteShortcut(deletion)
                },
                secondaryButton: .cancel(Text(copy("取消", "Cancel")))
            )
        }
        .task {
            if selectedPackageName.isEmpty {
                selectedPackageName = apps.first?.packageName.value ?? ""
            }
            scrcpyAvailability = await scrcpy.availability()
            while !Task.isCancelled {
                isScrcpyRunning = await scrcpy.isRunning(on: device)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                model.closeToolbox()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(copy("返回应用选择", "Back to app selection"))

            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text(copy("工具箱", "Toolbox"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            CurrentDeviceMenu()
            Button {
                Task { await model.loadApps() }
            } label: {
                Label(copy("刷新应用", "Refresh apps"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoadingApps)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var apkCard: some View {
        ToolCard(
            title: copy("安装 APK", "Install APK"),
            subtitle: copy("点击选择，或将 APK 拖到下方区域。", "Choose a file or drop an APK below."),
            symbol: "shippingbox.and.arrow.backward"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.secondary.opacity(0.55))
                    HStack(spacing: 10) {
                        Image(systemName: apkURL == nil ? "arrow.down.doc" : "checkmark.circle.fill")
                            .foregroundStyle(apkURL == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                        Text(apkURL?.lastPathComponent ?? copy("选择或拖入一个 .apk 文件", "Choose or drop one .apk file"))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }
                    .padding(12)
                }
                .frame(height: 62)
                .contentShape(Rectangle())
                .onTapGesture { isChoosingAPK = true }
                .dropDestination(for: URL.self) { urls, _ in acceptDroppedAPK(urls) }

                DisclosureGroup(copy("安装选项", "Install options")) {
                    HStack(spacing: 18) {
                        Toggle(copy("覆盖已有版本", "Replace existing"), isOn: $apkOptions.replaceExisting)
                        Toggle(copy("允许测试 APK", "Allow test APK"), isOn: $apkOptions.allowTestPackages)
                        Toggle(copy("授予权限", "Grant permissions"), isOn: $apkOptions.grantRuntimePermissions)
                        Toggle(copy("允许降级", "Allow downgrade"), isOn: $apkOptions.allowDowngrade)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.top, 7)
                }

                actionButton(copy("安装", "Install"), tool: .apk, disabled: apkURL == nil) {
                    guard let apkURL else { return }
                    let result = try await service.installAPK(at: apkURL, on: device, options: apkOptions)
                    await model.loadApps()
                    installedAppInfo = result.appInfo
                    installedPackageName = result.packageName?.value ?? ""
                    didInstallAPK = true
                    setFeedback(
                        .apk,
                        message: result.packageName == nil
                            ? copy("安装成功。请选择刚安装的应用以查看版本或直接打开。", "Installed. Select the installed app to view its version or open it.")
                            : copy("安装成功。", "Installed successfully."),
                        isError: false
                    )
                }

                if didInstallAPK {
                    Divider()
                    Text(copy("已安装应用", "Installed app"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    SearchableAppPicker(apps: apps, selection: $installedPackageName)
                    if let info = installedAppInfo {
                        AppInfoSummary(info: info)
                        Button(copy("打开应用", "Open app")) {
                            run(.apk) {
                                try await service.openApplication(info.packageName, on: device)
                                setFeedback(.apk, message: copy("应用已打开。", "App opened."), isError: false)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                feedbackView(.apk)
            }
        }
    }

    private var scrcpyCard: some View {
        ToolCard(
            title: copy("屏幕镜像", "Screen mirroring"),
            subtitle: copy("使用 scrcpy 显示并控制当前设备。", "Display and control this device with scrcpy."),
            symbol: "rectangle.on.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if isScrcpyRunning {
                    HStack {
                        Label(copy("镜像正在运行", "Mirroring is running"), systemImage: "record.circle")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(copy("关闭镜像", "Stop mirroring"), role: .destructive) {
                            run(.scrcpy) {
                                await scrcpy.stop(on: device)
                                isScrcpyRunning = false
                                setFeedback(.scrcpy, message: copy("已关闭屏幕镜像。", "Screen mirroring stopped."), isError: false)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                switch scrcpyAvailability {
                case .installRequired:
                    Text(copy("首次使用需从官方源下载约 12 MB，并校验完整性。", "First use downloads about 12 MB from the official source and verifies it."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link(copy("查看 scrcpy 官方项目", "View the official scrcpy project"), destination: ScrcpyManager.projectURL)
                    actionButton(
                        isScrcpyRunning ? copy("镜像运行中", "Mirroring is running") : copy("下载并启动", "Download and launch"),
                        tool: .scrcpy,
                        disabled: isScrcpyRunning
                    ) {
                        try await scrcpy.install()
                        try await scrcpy.launch(on: device)
                        scrcpyAvailability = await scrcpy.availability()
                        isScrcpyRunning = true
                        setFeedback(.scrcpy, message: copy("屏幕镜像已启动。", "Screen mirroring launched."), isError: false)
                    }
                case .available(let version, let managed):
                    Label(managed ? "scrcpy \(version)" : copy("系统 scrcpy", "System scrcpy"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    actionButton(
                        isScrcpyRunning ? copy("镜像运行中", "Mirroring is running") : copy("启动镜像", "Start mirroring"),
                        tool: .scrcpy,
                        disabled: isScrcpyRunning
                    ) {
                        try await scrcpy.launch(on: device)
                        isScrcpyRunning = true
                        setFeedback(.scrcpy, message: copy("屏幕镜像已启动。", "Screen mirroring launched."), isError: false)
                    }
                }
                feedbackView(.scrcpy)
            }
        }
    }

    private var deepLinkCard: some View {
        ToolCard(
            title: "Deeplink",
            subtitle: copy("通过 VIEW Intent 验证应用跳转。", "Test navigation through an Android VIEW intent."),
            symbol: "link"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("myapp://path or https://…", text: $deepLink)
                    .textFieldStyle(.roundedBorder)
                DisclosureGroup(
                    copy("高级选项", "Advanced options"),
                    isExpanded: $isDeepLinkAdvancedExpanded
                ) {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(copy("限制由指定应用处理（调试）", "Restrict handling to a specific app (debug)"), isOn: $deepLinkTargetsApp)
                        Text(
                            deepLinkTargetsApp
                                ? copy("Android 只会尝试用下方应用处理链接。", "Android will only try the selected app for this link.")
                                : copy("默认交给 Android 系统路由，行为与用户点击链接一致。", "Android system routing is used by default, matching a normal link tap.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if deepLinkTargetsApp {
                            SearchableAppPicker(apps: apps, selection: $selectedPackageName)
                        }
                    }
                    .padding(.top, 8)
                }
                HStack(spacing: 8) {
                    actionButton(
                        copy("打开", "Open"),
                        tool: .deepLink,
                        disabled: deepLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (deepLinkTargetsApp && selectedPackage == nil)
                    ) {
                        try await openDeepLink(deepLink, package: deepLinkTargetsApp ? selectedPackage : nil)
                    }
                    Button {
                        deepLinkDraft = DeepLinkShortcutDraft(
                            name: "",
                            deepLink: deepLink,
                            packageName: deepLinkTargetsApp ? selectedPackageName : ""
                        )
                    } label: {
                        Label(copy("收藏", "Favorite"), systemImage: "star")
                    }
                    .buttonStyle(.bordered)
                    .disabled(deepLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                savedDeepLinksSection
                feedbackView(.deepLink)
            }
        }
    }

    private var textCard: some View {
        ToolCard(
            title: copy("发送文本", "Send text"),
            subtitle: copy("兼容英文、数字和常用符号；不会保存输入历史。", "Supports ASCII text and common symbols; input is not saved."),
            symbol: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $textInputMode) {
                    Text(copy("普通文本", "Plain text")).tag(TextInputMode.text)
                    Text("JSON").tag(TextInputMode.json)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextEditor(text: $inputText)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .frame(height: 100, alignment: .topLeading)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.primary.opacity(0.12))
                    }
                HStack(spacing: 8) {
                    Button {
                        inputText = NSPasteboard.general.string(forType: .string) ?? ""
                        jsonValidationMessage = nil
                    } label: {
                        Label(copy("粘贴", "Paste"), systemImage: "doc.on.clipboard")
                    }
                    Button {
                        copyToPasteboard(inputText)
                    } label: {
                        Label(copy("复制", "Copy"), systemImage: "square.on.square")
                    }
                    Button {
                        inputText = ""
                        jsonValidationMessage = nil
                    } label: {
                        Label(copy("清空", "Clear"), systemImage: "xmark")
                    }
                    if textInputMode == .json {
                        Button {
                            validateJSON()
                        } label: {
                            Label(copy("检查 JSON", "Validate JSON"), systemImage: "checkmark.circle")
                        }
                    }
                    Spacer()
                    Toggle(copy("发送后回车", "Press Enter"), isOn: $pressEnter)
                        .toggleStyle(.checkbox)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                actionButton(copy("发送", "Send"), tool: .text, disabled: inputText.isEmpty) {
                    switch textInputMode {
                    case .text:
                        try await service.sendText(inputText, pressEnter: pressEnter, on: device)
                    case .json:
                        try await service.sendJSON(inputText, pressEnter: pressEnter, on: device)
                        inputText = try await service.normalizedJSON(inputText)
                        jsonValidationMessage = copy("JSON 格式正确，已按紧凑格式发送。", "Valid JSON sent in compact form.")
                    }
                    setFeedback(.text, message: copy("内容已发送。", "Content sent."), isError: false)
                }
                if let jsonValidationMessage {
                    Text(jsonValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                feedbackView(.text)

                Divider()
                HStack(spacing: 8) {
                    Button {
                        Task { await readClipboard() }
                    } label: {
                        Label {
                            Text(isReadingClipboard ? copy("正在读取…", "Reading…") : copy("读取手机剪贴板", "Read phone clipboard"))
                        } icon: {
                            if isReadingClipboard {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "clipboard")
                            }
                        }
                    }
                    .controlSize(.regular)
                    .disabled(isReadingClipboard)
                    if !clipboardContent.isEmpty {
                        Button {
                            copyToPasteboard(clipboardContent)
                        } label: {
                            Label(copy("复制", "Copy"), systemImage: "square.on.square")
                        }
                    }
                }
                .buttonStyle(.bordered)
                if let clipboardMessage {
                    Text(clipboardMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !clipboardContent.isEmpty {
                    Text(clipboardContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var screenshotCard: some View {
        ToolCard(
            title: copy("设备截图", "Device screenshot"),
            subtitle: copy("截取当前屏幕并保存为 PNG。", "Capture the current screen and save it as PNG."),
            symbol: "camera.viewfinder"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                actionButton(copy("截图并保存…", "Capture and save…"), tool: .screenshot) {
                    let data = try await service.screenshot(on: device)
                    screenshotURL = try await saveScreenshot(data)
                    setFeedback(.screenshot, message: copy("截图已保存。", "Screenshot saved."), isError: false)
                }
                if let screenshotURL {
                    Text(screenshotURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Button(copy("打开截图", "Open screenshot")) {
                            NSWorkspace.shared.open(screenshotURL)
                        }
                        Button(copy("在 Finder 中显示", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([screenshotURL])
                        }
                    }
                    .buttonStyle(.bordered)
                }
                feedbackView(.screenshot)
            }
        }
    }

    private var appControlCard: some View {
        ToolCard(
            title: copy("应用控制", "App control"),
            subtitle: copy("打开、关闭、重启或清除指定应用的数据。", "Open, close, restart, or clear data for a selected app."),
            symbol: "app.badge.checkmark"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.recentApps.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(copy("最近使用", "Recently used"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 7)],
                            alignment: .leading,
                            spacing: 7
                        ) {
                            ForEach(model.recentApps.prefix(6)) { app in
                                Button {
                                    selectedPackageName = app.packageName.value
                                    model.recordRecentApp(app)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "clock")
                                        Text(app.presentation.displayName)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .help(app.packageName.value)
                            }
                        }
                    }
                }
                SearchableAppPicker(
                    apps: apps,
                    selection: $selectedPackageName,
                    onSelect: model.recordRecentApp
                )
                HStack {
                    actionButton(copy("打开应用", "Open app"), tool: .appControl, disabled: selectedPackage == nil, tint: .green) {
                        guard let selectedPackage else { return }
                        try await service.openApplication(selectedPackage, on: device)
                        setFeedback(.appControl, message: copy("应用已打开。", "App opened."), isError: false)
                    }
                    Button(copy("关闭应用", "Close app")) {
                        run(.appControl) {
                            guard let selectedPackage else { return }
                            try await service.closeApplication(selectedPackage, on: device)
                            setFeedback(.appControl, message: copy("应用已关闭。", "App closed."), isError: false)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selectedPackage == nil || runningTools.contains(.appControl))
                    Button(copy("重启应用", "Restart app")) {
                        run(.appControl) {
                            guard let selectedPackage else { return }
                            try await service.restart(selectedPackage, on: device)
                            setFeedback(.appControl, message: copy("应用已重新启动。", "App restarted."), isError: false)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selectedPackage == nil || runningTools.contains(.appControl))
                }
                feedbackView(.appControl)

                Divider()
                currentActivitySection
                savedActivitiesSection
                feedbackView(.activity)

                Divider()
                Text(copy("清除应用数据", "Clear app data"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(copy("此操作会永久删除所选应用的本地数据，点击后需要再次确认。", "This permanently deletes local data for the selected app and requires confirmation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(copy("清除应用数据…", "Clear app data…"), role: .destructive) {
                    isConfirmingClearData = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedPackage == nil || runningTools.contains(.clearData))
                feedbackView(.clearData)
            }
            .alert(
                copy("确认清除应用数据？", "Clear app data?"),
                isPresented: $isConfirmingClearData
            ) {
                Button(copy("确认清除", "Clear data"), role: .destructive) {
                    guard let package = selectedPackage else { return }
                    run(.clearData) {
                        try await service.clearData(for: package, on: device)
                        setFeedback(.clearData, message: copy("应用数据已清除。", "App data cleared."), isError: false)
                    }
                }
                Button(copy("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(
                    copy(
                        "将永久删除 \(selectedPackage?.value ?? "") 的本地数据，此操作无法撤销。",
                        "Local data for \(selectedPackage?.value ?? "") will be permanently deleted. This cannot be undone."
                    )
                )
            }
        }
    }

    private var currentActivitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(copy("当前 Activity", "Current Activity"))
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    activityDraft = ActivityShortcutDraft(
                        name: "",
                        component: currentActivity?.value ?? selectedPackage.map { "\($0.value)/" } ?? ""
                    )
                } label: {
                    Label(copy("新增", "Add"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            Text(copy("读取设备当前前台页面，也可以粘贴完整 adb shell am start -n 命令。", "Read the foreground screen, or paste a complete adb shell am start -n command."))
                .font(.caption)
                .foregroundStyle(.secondary)
            actionButton(
                copy("读取当前 Activity", "Read current Activity"),
                tool: .activity,
                disabled: selectedPackage == nil
            ) {
                currentActivity = try await service.currentActivity(on: device)
                setFeedback(.activity, message: copy("当前 Activity 已更新。", "Current Activity updated."), isError: false)
            }
            if let currentActivity {
                VStack(alignment: .leading, spacing: 7) {
                    Text(currentActivity.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    if currentActivity.packageName != selectedPackage {
                        Label(
                            copy("当前前台页面不属于所选应用。", "The foreground screen does not belong to the selected app."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        Button(copy("复制", "Copy")) { copyToPasteboard(currentActivity.value) }
                        Button(copy("打开", "Open")) {
                            run(.activity) { try await openActivity(currentActivity) }
                        }
                        Button(copy("保存", "Save")) {
                            activityDraft = ActivityShortcutDraft(name: "", component: currentActivity.value)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var savedActivitiesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(copy("已保存 Activity", "Saved Activities"))
                    .font(.callout.weight(.semibold))
                Spacer()
                Toggle(copy("显示全部", "Show all"), isOn: $showsAllActivities)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if !shortcuts.activities.isEmpty {
                TextField(copy("搜索名称、包名或 Activity", "Search name, package, or Activity"), text: $activitySearch)
                    .textFieldStyle(.roundedBorder)
            }
            let values = filteredActivities
            if values.isEmpty {
                Text(activityEmptyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(values) { shortcut in
                            ActivityShortcutRow(
                                shortcut: shortcut,
                                open: { run(.activity) { try await openActivity(shortcut.component) } },
                                copy: { copyToPasteboard(shortcut.component.value) },
                                edit: { activityDraft = ActivityShortcutDraft(shortcut) },
                                delete: { pendingShortcutDeletion = .activity(shortcut.id, shortcut.name) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var savedDeepLinksSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(copy("已收藏 Deeplink", "Favorite Deeplinks"))
                .font(.callout.weight(.semibold))
            if !shortcuts.deepLinks.isEmpty {
                TextField(copy("搜索名称、链接或应用", "Search name, link, or app"), text: $deepLinkSearch)
                    .textFieldStyle(.roundedBorder)
            }
            let values = filteredDeepLinks
            if values.isEmpty {
                Text(shortcuts.deepLinks.isEmpty
                     ? copy("还没有收藏的 Deeplink。", "No favorite Deeplinks yet.")
                     : copy("没有匹配的 Deeplink。", "No matching Deeplinks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(values) { shortcut in
                            DeepLinkShortcutRow(
                                shortcut: shortcut,
                                open: { run(.deepLink) { try await openDeepLink(shortcut.deepLink, package: shortcut.packageName) } },
                                fill: {
                                    deepLink = shortcut.deepLink
                                    deepLinkTargetsApp = shortcut.packageName != nil
                                    if let package = shortcut.packageName { selectedPackageName = package.value }
                                },
                                copy: { copyToPasteboard(shortcut.deepLink) },
                                edit: { deepLinkDraft = DeepLinkShortcutDraft(shortcut) },
                                delete: { pendingShortcutDeletion = .deepLink(shortcut.id, shortcut.name) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var filteredActivities: [SavedActivityShortcut] {
        let query = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = showsAllActivities
            ? shortcuts.activities
            : shortcuts.activities.filter { $0.component.packageName == selectedPackage }
        guard !query.isEmpty else { return scoped }
        return scoped.filter {
            $0.name.lowercased().contains(query)
                || $0.component.value.lowercased().contains(query)
                || $0.note.lowercased().contains(query)
        }
    }

    private var activityEmptyMessage: String {
        if shortcuts.activities.isEmpty {
            return copy("还没有保存的 Activity。", "No saved Activities yet.")
        }
        if !activitySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return copy("没有匹配的 Activity。", "No matching Activities.")
        }
        if !showsAllActivities {
            return copy("当前应用没有已保存的 Activity，可切换“显示全部”。", "No saved Activities for this app. Turn on Show all to view others.")
        }
        return copy("还没有保存的 Activity。", "No saved Activities yet.")
    }

    private var filteredDeepLinks: [SavedDeepLinkShortcut] {
        let query = deepLinkSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return shortcuts.deepLinks }
        return shortcuts.deepLinks.filter {
            $0.name.lowercased().contains(query)
                || $0.deepLink.lowercased().contains(query)
                || ($0.packageName?.value.lowercased().contains(query) ?? false)
                || $0.note.lowercased().contains(query)
        }
    }

    private var deviceInfoCard: some View {
        ToolCard(
            title: copy("设备信息", "Device information"),
            subtitle: copy("读取屏幕、电量、存储和常用调试标识。", "Read screen, battery, storage, and common debugging identifiers."),
            symbol: "info.circle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                actionButton(copy("读取设备信息", "Read device information"), tool: .deviceInfo) {
                    deviceInfo = try await service.deviceInfo(on: device)
                    setFeedback(.deviceInfo, message: copy("设备信息已更新。", "Device information updated."), isError: false)
                }
                if let info = deviceInfo {
                    DeviceInfoSummary(info: info)
                    HStack {
                        Button(copy("复制全部", "Copy all")) { copyToPasteboard(info.formatted) }
                        if let advertisingID = info.advertisingID {
                            Button(copy("复制 GAID", "Copy GAID")) { copyToPasteboard(advertisingID) }
                        }
                    }
                    .buttonStyle(.bordered)
                    if info.advertisingID == nil {
                        Text(copy("GAID 不可用：设备、Android 版本或隐私设置可能禁止通过 ADB 读取。", "GAID unavailable: the device, Android version, or privacy settings may block ADB access."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                feedbackView(.deviceInfo)
            }
        }
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        tool: Tool,
        disabled: Bool = false,
        destructive: Bool = false,
        tint: Color? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil) {
            run(tool, operation: operation)
        } label: {
            HStack(spacing: 7) {
                if runningTools.contains(tool) { ProgressView().controlSize(.small) }
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(destructive ? .red : tint)
        .disabled(disabled || runningTools.contains(tool))
    }

    @ViewBuilder
    private func feedbackView(_ tool: Tool) -> some View {
        if let feedback = feedback[tool] {
            Text(feedback.message)
                .font(.caption)
                .foregroundStyle(feedback.isError ? .red : .secondary)
                .lineLimit(5)
                .textSelection(.enabled)
        }
    }

    private func run(
        _ tool: Tool,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        feedback[tool] = nil
        runningTools.insert(tool)
        Task { @MainActor in
            do {
                try await operation()
            } catch {
                setFeedback(tool, message: errorMessage(error, for: tool), isError: true)
            }
            runningTools.remove(tool)
        }
    }

    @discardableResult
    private func acceptDroppedAPK(_ urls: [URL]) -> Bool {
        guard urls.count == 1,
              let url = urls.first,
              url.isFileURL,
              url.pathExtension.lowercased() == "apk" else {
            setFeedback(.apk, message: copy("请拖入一个 .apk 文件。", "Drop exactly one .apk file."), isError: true)
            return false
        }
        apkURL = url.standardizedFileURL
        installedPackageName = ""
        installedAppInfo = nil
        didInstallAPK = false
        feedback[.apk] = nil
        return true
    }

    private func loadInstalledAppInfo() {
        installedAppInfo = nil
        guard let installedPackage else { return }
        Task { @MainActor in
            installedAppInfo = try? await service.applicationInfo(for: installedPackage, on: device)
        }
    }

    private func openDeepLink(_ value: String, package: AndroidPackageName?) async throws {
        let output = try await service.openDeepLink(value, package: package, on: device)
        setFeedback(.deepLink, message: output.isEmpty ? copy("已发送。", "Sent.") : output, isError: false)
    }

    private func openActivity(_ component: AndroidActivityComponent) async throws {
        let output = try await service.openActivity(component, on: device)
        setFeedback(.activity, message: output.isEmpty ? copy("Activity 已打开。", "Activity opened.") : output, isError: false)
    }

    private func saveActivityShortcut(_ shortcut: SavedActivityShortcut) {
        if let index = shortcuts.activities.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts.activities[index] = shortcut
        } else {
            shortcuts.activities.append(shortcut)
        }
        shortcuts.activities.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistShortcuts(for: .activity, successMessage: copy("Activity 已保存。", "Activity saved."))
    }

    private func saveDeepLinkShortcut(_ shortcut: SavedDeepLinkShortcut) {
        if let index = shortcuts.deepLinks.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts.deepLinks[index] = shortcut
        } else {
            shortcuts.deepLinks.append(shortcut)
        }
        shortcuts.deepLinks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistShortcuts(for: .deepLink, successMessage: copy("Deeplink 已收藏。", "Deeplink favorited."))
    }

    private func deleteShortcut(_ deletion: ShortcutDeletion) {
        switch deletion {
        case .activity(let id, _):
            shortcuts.activities.removeAll(where: { $0.id == id })
            persistShortcuts(for: .activity, successMessage: copy("Activity 收藏已删除。", "Activity favorite deleted."))
        case .deepLink(let id, _):
            shortcuts.deepLinks.removeAll(where: { $0.id == id })
            persistShortcuts(for: .deepLink, successMessage: copy("Deeplink 收藏已删除。", "Deeplink favorite deleted."))
        }
    }

    private func persistShortcuts(for tool: Tool, successMessage: String) {
        do {
            try shortcutStore.save(shortcuts)
            setFeedback(tool, message: successMessage, isError: false)
        } catch {
            setFeedback(tool, message: copy("无法保存收藏。", "Could not save favorite."), isError: true)
        }
    }

    private func validateJSON() {
        jsonValidationMessage = nil
        feedback[.text] = nil
        Task { @MainActor in
            do {
                inputText = try await service.normalizedJSON(inputText)
                jsonValidationMessage = copy("JSON 格式正确，已转换为紧凑格式。", "Valid JSON. Converted to compact form.")
            } catch {
                setFeedback(
                    .text,
                    message: copy("JSON 格式不正确，请检查括号、引号和逗号。", "Invalid JSON. Check brackets, quotation marks, and commas."),
                    isError: true
                )
            }
        }
    }

    @MainActor
    private func saveScreenshot(_ data: Data) async throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "FantaLogcat-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func readClipboard() async {
        isReadingClipboard = true
        defer { isReadingClipboard = false }
        clipboardMessage = nil
        do {
            let text = try await service.readClipboard(on: device)
            clipboardContent = text
            if text.isEmpty {
                clipboardMessage = copy("剪贴板为空。", "Clipboard is empty.")
            }
        } catch {
            clipboardContent = ""
            if error as? ADBToolServiceError == .clipboardReadingUnavailable {
                clipboardMessage = copy(
                    "当前设备系统未开放 ADB 剪贴板读取；可继续使用上方“粘贴”将 Mac 剪贴板内容发送到设备。",
                    "This device does not expose clipboard reading to ADB. You can still use Paste above to send Mac clipboard text to the device."
                )
            } else if let adbError = error as? ADBError,
               case .commandFailed(_, let summary) = adbError,
               !summary.isEmpty {
                clipboardMessage = copy("命令执行失败：\(summary)", "Command failed: \(summary)")
            } else {
                clipboardMessage = copy("命令执行失败：\(String(describing: error))", "Command failed: \(String(describing: error))")
            }
        }
    }

    private func setFeedback(_ tool: Tool, message: String, isError: Bool) {
        feedback[tool] = Feedback(message: message, isError: isError)
    }

    private func errorMessage(_ error: Error, for tool: Tool) -> String {
        if error is CancellationError { return copy("操作已取消。", "Operation cancelled.") }
        if let scrcpyError = error as? ScrcpyManagerError, scrcpyError == .alreadyRunning {
            return copy("当前设备的镜像已经在运行。", "Mirroring is already running for this device.")
        }
        if let validation = error as? ADBValidationError {
            switch validation {
            case .invalidAPK:
                return copy("请选择有效的 APK 文件。", "Choose a valid APK file.")
            case .invalidDeepLink:
                return copy("请输入包含 scheme 的有效 Deeplink。", "Enter a valid deep link with a scheme.")
            case .invalidActivityComponent:
                return copy("没有读取到有效 Activity，请确认应用位于前台或检查 Component。", "No valid Activity was found. Bring the app to the foreground or check the component.")
            case .invalidInputText:
                return copy("文本只能包含英文、数字、空格和常用符号，且不超过 1000 字节。", "Use ASCII letters, numbers, spaces, and common symbols up to 1000 bytes.")
            case .invalidJSON:
                return copy("JSON 格式不正确，请检查括号、引号和逗号。", "Invalid JSON. Check brackets, quotation marks, and commas.")
            case .invalidScreenshot:
                return copy("设备没有返回有效截图。", "The device did not return a valid screenshot.")
            default:
                break
            }
        }
        if let serviceError = error as? ADBToolServiceError,
           case .activityNotAccessible(let details) = serviceError {
            return copy(
                "该 Activity 未导出，且应用不允许 run-as。只有可调试 APK、root 设备，或应用将 Activity 设为 exported 时才能从外部打开。\n\(details)",
                "This Activity is not exported and the app does not allow run-as. External launch requires a debuggable APK, a rooted device, or an exported Activity.\n\(details)"
            )
        }
        if let adbError = error as? ADBError,
           case .commandFailed(_, let summary) = adbError,
           tool != .text,
           !summary.isEmpty {
            return summary
        }
        return copy("操作失败，请检查设备状态后重试。", "Operation failed. Check the device and try again.")
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        model.copy(chinese, english)
    }
}

private enum ShortcutDeletion: Identifiable {
    case activity(UUID, String)
    case deepLink(UUID, String)

    var id: String {
        switch self {
        case .activity(let id, _): "activity-\(id)"
        case .deepLink(let id, _): "deeplink-\(id)"
        }
    }

    var name: String {
        switch self {
        case .activity(_, let name), .deepLink(_, let name): name
        }
    }
}

private struct ActivityShortcutDraft: Identifiable {
    let id: UUID
    var name: String
    var component: String
    var note: String

    init(id: UUID = UUID(), name: String, component: String, note: String = "") {
        self.id = id
        self.name = name
        self.component = component
        self.note = note
    }

    init(_ shortcut: SavedActivityShortcut) {
        self.init(
            id: shortcut.id,
            name: shortcut.name,
            component: shortcut.component.value,
            note: shortcut.note
        )
    }
}

private struct DeepLinkShortcutDraft: Identifiable {
    let id: UUID
    var name: String
    var deepLink: String
    var packageName: String
    var note: String

    init(
        id: UUID = UUID(),
        name: String,
        deepLink: String,
        packageName: String = "",
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.deepLink = deepLink
        self.packageName = packageName
        self.note = note
    }

    init(_ shortcut: SavedDeepLinkShortcut) {
        self.init(
            id: shortcut.id,
            name: shortcut.name,
            deepLink: shortcut.deepLink,
            packageName: shortcut.packageName?.value ?? "",
            note: shortcut.note
        )
    }
}

private struct ActivityShortcutEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ActivityShortcutDraft
    @State private var validationMessage: String?
    let save: (SavedActivityShortcut) -> Void

    init(draft: ActivityShortcutDraft, save: @escaping (SavedActivityShortcut) -> Void) {
        _draft = State(initialValue: draft)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("保存 Activity", "Save Activity"))
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("名称", "Name")).font(.caption.weight(.semibold))
                TextField(copy("例如：产品调试后台", "For example: Product debugger"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Component").font(.caption.weight(.semibold))
                TextField("com.example/com.example.DebugActivity", text: $draft.component)
                    .textFieldStyle(.roundedBorder)
                Text(copy("可以直接粘贴完整的 adb shell am start -n 命令。", "You can paste a complete adb shell am start -n command."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("备注（可选）", "Note (optional)")).font(.caption.weight(.semibold))
                TextField(copy("用途或测试说明", "Usage or testing notes"), text: $draft.note)
                    .textFieldStyle(.roundedBorder)
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(copy("取消", "Cancel")) { dismiss() }
                Button(copy("保存", "Save")) { validateAndSave() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func validateAndSave() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            validationMessage = copy("请输入 1–100 个字符的名称。", "Enter a name between 1 and 100 characters.")
            return
        }
        guard let component = try? AndroidActivityComponent(draft.component) else {
            validationMessage = copy("请输入有效的 Component 或完整 ADB 命令。", "Enter a valid component or complete ADB command.")
            return
        }
        save(SavedActivityShortcut(
            id: draft.id,
            name: name,
            component: component,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss()
    }

    private func copy(_ chinese: String, _ english: String) -> String { model.copy(chinese, english) }
}

private struct DeepLinkShortcutEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DeepLinkShortcutDraft
    @State private var restrictToApp: Bool
    @State private var validationMessage: String?
    let apps: [AppDescriptor]
    let save: (SavedDeepLinkShortcut) -> Void

    init(
        draft: DeepLinkShortcutDraft,
        apps: [AppDescriptor],
        save: @escaping (SavedDeepLinkShortcut) -> Void
    ) {
        _draft = State(initialValue: draft)
        _restrictToApp = State(initialValue: !draft.packageName.isEmpty)
        self.apps = apps
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("收藏 Deeplink", "Favorite Deeplink"))
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("名称", "Name")).font(.caption.weight(.semibold))
                TextField(copy("例如：打开活动页面", "For example: Open campaign"), text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Deeplink").font(.caption.weight(.semibold))
                TextField("myapp://path or https://…", text: $draft.deepLink)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(copy("限制由指定应用处理", "Restrict to a specific app"), isOn: $restrictToApp)
            if restrictToApp {
                SearchableAppPicker(apps: apps, selection: $draft.packageName)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(copy("备注（可选）", "Note (optional)")).font(.caption.weight(.semibold))
                TextField(copy("用途或测试说明", "Usage or testing notes"), text: $draft.note)
                    .textFieldStyle(.roundedBorder)
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(copy("取消", "Cancel")) { dismiss() }
                Button(copy("保存", "Save")) { validateAndSave() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 540)
    }

    private func validateAndSave() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            validationMessage = copy("请输入 1–100 个字符的名称。", "Enter a name between 1 and 100 characters.")
            return
        }
        guard let link = try? ADBDeepLink(draft.deepLink) else {
            validationMessage = copy("请输入包含 scheme 的有效 Deeplink。", "Enter a valid Deeplink with a scheme.")
            return
        }
        let package: AndroidPackageName?
        if restrictToApp {
            guard let value = try? AndroidPackageName(draft.packageName) else {
                validationMessage = copy("请选择目标应用。", "Choose a target app.")
                return
            }
            package = value
        } else {
            package = nil
        }
        save(SavedDeepLinkShortcut(
            id: draft.id,
            name: name,
            deepLink: link.value,
            packageName: package,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        dismiss()
    }

    private func copy(_ chinese: String, _ english: String) -> String { model.copy(chinese, english) }
}

private struct ActivityShortcutRow: View {
    @EnvironmentObject private var model: AppModel
    let shortcut: SavedActivityShortcut
    let open: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.name).font(.callout.weight(.semibold))
                Text(shortcut.component.value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !shortcut.note.isEmpty {
                    Text(shortcut.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(model.copy("打开", "Open"), action: open).buttonStyle(.borderedProminent)
            Menu {
                Button(model.copy("复制 Component", "Copy component"), action: copy)
                Button(model.copy("编辑", "Edit"), action: edit)
                Divider()
                Button(model.copy("删除", "Delete"), role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeepLinkShortcutRow: View {
    @EnvironmentObject private var model: AppModel
    let shortcut: SavedDeepLinkShortcut
    let open: () -> Void
    let fill: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.name).font(.callout.weight(.semibold))
                Text(shortcut.deepLink)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let package = shortcut.packageName {
                    Text(package.value).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.copy("打开", "Open"), action: open).buttonStyle(.borderedProminent)
            Menu {
                Button(model.copy("填入输入框", "Fill input"), action: fill)
                Button(model.copy("复制链接", "Copy link"), action: copy)
                Button(model.copy("编辑", "Edit"), action: edit)
                Divider()
                Button(model.copy("删除", "Delete"), role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SearchableAppPicker: View {
    @EnvironmentObject private var model: AppModel
    let apps: [AppDescriptor]
    @Binding var selection: String
    let onSelect: (AppDescriptor) -> Void
    @State private var isPresented = false
    @State private var search = ""
    @State private var highlightedAppID: String?
    @State private var isSearchFocused = false

    init(
        apps: [AppDescriptor],
        selection: Binding<String>,
        onSelect: @escaping (AppDescriptor) -> Void = { _ in }
    ) {
        self.apps = apps
        _selection = selection
        self.onSelect = onSelect
    }

    private var filteredApps: [AppDescriptor] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? apps
            : AppSelectionPresentation.searchResults(apps, query: trimmed)
    }

    private var selectedApp: AppDescriptor? {
        apps.first(where: { $0.packageName.value == selection })
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "app")
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedApp?.presentation.displayName ?? model.copy("选择应用", "Choose an app"))
                        .foregroundStyle(.primary)
                    if let selectedApp {
                        Text(selectedApp.packageName.value)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14, alignment: .center)
                    ZStack(alignment: .leading) {
                        KeyboardNavigableTextField(
                            text: $search,
                            onMove: moveHighlight,
                            onSubmit: chooseHighlightedApp,
                            onFocusChange: { isSearchFocused = $0 }
                        )
                        if search.isEmpty {
                            Text(model.copy("搜索应用名称或包名", "Search name or package"))
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSearchFocused ? Color.accentColor : Color.primary.opacity(0.2),
                            lineWidth: isSearchFocused ? 2 : 1
                        )
                }
                .padding(12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredApps) { app in
                                Button {
                                    choose(app)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(app.presentation.displayName).foregroundStyle(.primary)
                                            Text(app.packageName.value)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selection == app.packageName.value {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .background(
                                        highlightedAppID == app.id
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(app.id)
                            }
                            if filteredApps.isEmpty {
                                Text(model.copy("没有匹配的应用", "No matching apps"))
                                    .foregroundStyle(.secondary)
                                    .padding(24)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 5)
                    }
                    .frame(height: 250)
                    .onChange(of: highlightedAppID) { appID in
                        guard let appID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(appID, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 390)
            .onAppear {
                highlightedAppID = filteredApps.first(where: { $0.id == selection })?.id
                    ?? filteredApps.first?.id
            }
            .onChange(of: search) { _ in
                highlightedAppID = filteredApps.first?.id
            }
        }
        .onChange(of: isPresented) { presented in
            guard !presented else { return }
            search = ""
            highlightedAppID = nil
        }
    }

    private func moveHighlight(_ direction: MoveCommandDirection) {
        guard !filteredApps.isEmpty else { return }
        let currentIndex = highlightedAppID.flatMap { id in
            filteredApps.firstIndex(where: { $0.id == id })
        } ?? 0
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(0, currentIndex - 1)
        case .down:
            nextIndex = min(filteredApps.count - 1, currentIndex + 1)
        default:
            return
        }
        highlightedAppID = filteredApps[nextIndex].id
    }

    private func chooseHighlightedApp() {
        guard let highlightedAppID,
              let app = filteredApps.first(where: { $0.id == highlightedAppID }) else { return }
        choose(app)
    }

    private func choose(_ app: AppDescriptor) {
        selection = app.packageName.value
        onSelect(app)
        isPresented = false
        search = ""
    }
}

private struct KeyboardNavigableTextField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let textField = AutoFocusTextField()
        textField.delegate = context.coordinator
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.placeholderString = ""
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ textField: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        textField.placeholderString = ""
        if let editor = textField.currentEditor() as? NSTextView {
            if editor.string != text {
                editor.string = text
                editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            }
            return
        }
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyboardNavigableTextField

        init(parent: KeyboardNavigableTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let editorText = (textField.currentEditor() as? NSTextView)?.string
                ?? textField.stringValue
            parent.text = editorText
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
            parent.onFocusChange(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(.up)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(.down)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            default:
                return false
            }
        }
    }

    final class AutoFocusTextField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
}

private struct AppInfoSummary: View {
    let info: AndroidAppInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(info.packageName.value).font(.caption.monospaced())
            Text("Version \(info.versionName) (\(info.versionCode))")
            Text("SDK min \(info.minSDK) · target \(info.targetSDK)")
            if info.lastUpdateTime != "—" { Text("Updated \(info.lastUpdateTime)") }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DeviceInfoSummary: View {
    let info: AndroidDeviceInfo

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            row("Serial", info.serial)
            row("Device", "\(info.manufacturer) \(info.model)")
            row("Android", "\(info.androidVersion) · SDK \(info.sdk)")
            row("ABI", info.abi)
            row("Screen", "\(info.screenSize) · \(info.screenDensity)")
            row("Battery", info.battery)
            row("Storage", info.dataStorage)
            row("GAID", info.advertisingID ?? "Unavailable")
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).fontDesign(.monospaced)
        }
    }
}

private struct ToolCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var isDestructive = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isDestructive ? .red.opacity(0.35) : .primary.opacity(0.08))
        }
    }
}
