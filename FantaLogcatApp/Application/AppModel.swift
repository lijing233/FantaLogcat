import SwiftUI

enum AppPhase: Equatable {
    case preparingADB
    case selectingDevice
    case selectingApp
    case toolbox
    case viewingLogs
}

enum ADBPreparationState: Equatable {
    case checking
    case licenseRequired
    case installing
    case failed(String)
}

enum LogCaptureState: Equatable {
    case waitingForAppLaunch
    case loadingRecentLogs
    case followingLiveLogs
    case stopped
}

enum ConnectionRecoveryState: Equatable {
    case idle
    case discoveringADBDevices
    case reconnectingSavedTCPIP(String)
    case waitingForTLSDiscovery
    case completed
}

@MainActor
final class AppModel: ObservableObject {
    private enum RetryOperation {
        case check
        case install
    }

    private enum LogStreamOutcome: Sendable {
        case streamEnded
        case pidsChanged
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: AppPhase = .preparingADB
    @Published private(set) var adbPreparation: ADBPreparationState = .checking
    @Published private(set) var deviceConnection: DeviceConnectionState = .scanning
    @Published private(set) var selectedDevice: DeviceDescriptor?
    @Published private(set) var availableApps: [AppDescriptor] = []
    @Published private(set) var selectedApp: AppDescriptor?
    @Published private(set) var recentApps: [AppDescriptor] = []
    @Published private(set) var favoriteApps: [AppDescriptor] = []
    @Published private(set) var isLoadingApps = false
    @Published private(set) var logEvents: [LogEvent] = []
    @Published private(set) var filteredLogEvents: [LogEvent] = []
    @Published private(set) var isLogStreaming = false
    @Published private(set) var logStreamError: String?
    @Published private(set) var logHistoryError: String?
    @Published private(set) var logCaptureState: LogCaptureState = .stopped
    @Published private(set) var logFilter = LogFilter()
    @Published private(set) var savedKeywords: [SavedKeyword] = []
    @Published private(set) var isLogPresentationPaused = false
    @Published private(set) var pendingLogEventCount = 0
    @Published var isShowingSettings = false
    @Published private(set) var settings: AppSettings
    @Published private(set) var appearancePreview: AppAppearance?
    @Published private(set) var connectionRecoveryState: ConnectionRecoveryState = .idle
    @Published private(set) var recentDeviceConnections: [RecentDeviceConnection] = []

    private(set) var adbToolService: ADBToolService?
    private(set) var scrcpyManager: ScrcpyManager?
    private(set) var wirelessService: (any WirelessDebugServiceProtocol)?

    var language: AppLanguage { settings.language }
    var appearance: AppAppearance { settings.appearance }
    var effectiveAppearance: AppAppearance { appearancePreview ?? appearance }
    var captureSettings: LogCaptureSettings { settings.capture }

    private var defaultDevicePhase: AppPhase {
        settings.defaultDeviceDestination == .toolbox ? .toolbox : .selectingApp
    }

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
    private var deviceService: (any DeviceServiceProtocol)?
    private var appCatalog: (any AppCatalogProtocol)?
    private var logSession: (any LogSessionProtocol)?
    private var logTask: Task<Void, Never>?
    private var logCaptureGeneration: UInt64 = 0
    private var logFlushTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration: UInt64 = 0
    private let cacheLimitsOverride: CacheLimits?
    private var logBuffer: LogRingBuffer
    private var nextLogEventID: UInt64 = 1
    private var pendingLogEvents: [LogEvent] = []
    private var pendingLogTextBytes = 0
    private let keywordStore: any LogKeywordStoreProtocol
    private let appSelectionStore: any AppSelectionStoreProtocol
    private let settingsStore: any AppSettingsStore
    private let recentDeviceStore: any RecentDeviceConnectionStore
    private var retryOperation: RetryOperation = .check
    private var consecutiveDisconnectCount = 0
    private var knownDeviceSerials = Set<String>()
    private var switchProtectionDeadline: ContinuousClock.Instant?
    private var preferredWirelessSerial: String?
    private var preferredWirelessUntil: ContinuousClock.Instant?

    private static let devicePollInterval = Duration.seconds(2)
    private static let disconnectConfirmationThreshold = 2

    init(
        environment: AppEnvironment,
        cacheLimits: CacheLimits? = nil,
        keywordStore: any LogKeywordStoreProtocol = UserDefaultsLogKeywordStore(),
        settingsStore: any AppSettingsStore = UserDefaultsAppSettingsStore(),
        recentDeviceStore: any RecentDeviceConnectionStore = UserDefaultsRecentDeviceConnectionStore()
    ) {
        let settings = settingsStore.settings.normalized
        self.environment = environment
        cacheLimitsOverride = cacheLimits
        self.settings = settings
        appearancePreview = nil
        logBuffer = LogRingBuffer(limits: cacheLimits ?? settings.capture.cacheLimits)
        self.keywordStore = keywordStore
        savedKeywords = keywordStore.keywords
        appSelectionStore = environment.makeAppSelectionStore()
        self.settingsStore = settingsStore
        self.recentDeviceStore = recentDeviceStore
        recentDeviceConnections = recentDeviceStore.records
    }

    func prepareADB() async {
        guard phase == .preparingADB else { return }
        retryOperation = .check
        adbPreparation = .checking
        do {
            let installer = try resolveInstaller()
            switch await installer.state() {
            case .notInstalled:
                adbPreparation = .licenseRequired
            case .ready(let installation):
                resolveDeviceService(for: installation)
                phase = .selectingDevice
            }
        } catch {
            adbPreparation = .failed(Self.errorCode(error))
        }
    }

    /// 启动流程：准备 ADB → 刷新设备（单台直接进入、多台命中最近设备）→ 无设备时后台恢复最近无线连接。
    func startup() async {
        await prepareADB()
        guard phase == .selectingDevice else { return }
        await refreshDevices()
        if case .noDevice = deviceConnection {
            startRecovery(for: nil)
        }
    }

    private func recordRecentDevice(_ device: DeviceDescriptor) {
        // 保留旧记录里用户手动关闭的"自动恢复"开关，避免每次记录都把它重置回开启。
        let existing = recentDeviceConnections.first(where: { $0.serial == device.serial.value })
        let record = RecentDeviceConnection(
            serial: device.serial.value,
            displayName: device.displayName,
            transport: device.transport,
            tcpIPAddress: device.transport == .wirelessTCPIP ? device.serial.value : nil,
            lastUsedAt: Date(),
            autoRestoreEnabled: existing?.autoRestoreEnabled ?? true
        )
        recentDeviceStore.upsert(record)
        recentDeviceConnections = recentDeviceStore.records
    }

    private func autoSelectLastUsedDevice(among devices: [DeviceDescriptor]) {
        for record in recentDeviceConnections {
            if let device = devices.first(where: { $0.id == record.serial }) {
                selectDevice(device)
                return
            }
        }
    }

    func installADB() async {
        guard phase == .preparingADB,
              adbPreparation == .licenseRequired
                || (isFailed && retryOperation == .install) else {
            return
        }
        retryOperation = .install
        adbPreparation = .installing
        do {
            let installer = try resolveInstaller()
            let installation = try await installer.install(acceptingLicense: true)
            resolveDeviceService(for: installation)
            phase = .selectingDevice
            await refreshDevices()
        } catch {
            adbPreparation = .failed(Self.errorCode(error))
        }
    }

    func retryADB() async {
        switch retryOperation {
        case .check:
            await prepareADB()
        case .install:
            await installADB()
        }
    }

    func refreshDevices() async {
        guard phase == .selectingDevice else { return }
        deviceConnection = .scanning
        do {
            guard let deviceService else {
                deviceConnection = .failed("device_service_unavailable")
                return
            }
            let state = try await deviceService.refresh()
            applyDeviceConnection(state)
            if case .selectionRequired(let devices) = state {
                autoSelectLastUsedDevice(among: devices)
            }
            startDeviceMonitoringIfNeeded()
        } catch {
            applyDeviceConnection(.failed(Self.errorCode(error)))
            startDeviceMonitoringIfNeeded()
        }
    }

    func monitorDeviceConnection() async {
        guard phase != .preparingADB, let deviceService else { return }
        do {
            applyMonitoredConnection(try await deviceService.refresh())
        } catch {
            applyMonitoredConnection(.failed(Self.errorCode(error)))
        }
    }

    func selectDevice(_ device: DeviceDescriptor) {
        guard phase == .selectingDevice else { return }
        selectedDevice = device
        deviceConnection = .connected(device)
        consecutiveDisconnectCount = 0
        recordRecentDevice(device)
        phase = defaultDevicePhase
        Task { await loadApps() }
    }

    func loadApps() async {
        guard phase == .selectingApp || phase == .toolbox,
              let selectedDevice,
              !isLoadingApps else { return }
        guard let appCatalog else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            availableApps = try await appCatalog.listApps(on: selectedDevice)
            refreshAppSections()
        }
        catch { availableApps = [] }
    }

    var settingsDraft: AppSettings {
        settings
    }

    func saveSettings(_ draft: AppSettings) throws {
        let value = draft.normalized
        try settingsStore.save(value)
        settings = value
    }

    func previewAppearance(_ appearance: AppAppearance) {
        appearancePreview = appearance
    }

    func endAppearancePreview() {
        appearancePreview = nil
    }

    func copy(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }

    func selectApp(_ app: AppDescriptor) {
        guard let selectedDevice, appCatalog != nil, logSession != nil else { return }
        logTask?.cancel()
        appSelectionStore.recordRecent(app.packageName.value)
        refreshAppSections()
        selectedApp = app
        resetLogStorage()
        logStreamError = nil
        logHistoryError = nil
        isLogStreaming = false
        logCaptureState = .waitingForAppLaunch
        phase = .viewingLogs
        startLogCapture(for: app, on: selectedDevice)
    }

    func recordRecentApp(_ app: AppDescriptor) {
        appSelectionStore.recordRecent(app.packageName.value)
        refreshAppSections()
    }

    func openToolbox() {
        guard selectedDevice != nil,
              adbToolService != nil,
              scrcpyManager != nil else { return }
        phase = .toolbox
        Task { await loadApps() }
    }

    func closeToolbox() {
        guard phase == .toolbox else { return }
        phase = .selectingApp
    }

    func returnToAppSelection() {
        logTask?.cancel()
        logTask = nil
        logCaptureGeneration &+= 1
        resetLogStorage()
        isLogStreaming = false
        logStreamError = nil
        logHistoryError = nil
        logCaptureState = .stopped
        phase = .selectingApp
    }

    func clearLogs() {
        resetLogStorage(resetEventIDs: false)
    }

    func setLogLevels(_ levels: Set<LogPriority>) {
        logFilter.levels = levels
        rebuildFilteredLogEvents()
    }

    func setLogKeyword(_ keyword: String) {
        logFilter.keyword = keyword
        rebuildFilteredLogEvents()
    }

    func clearLogFilters() {
        logFilter = LogFilter()
        rebuildFilteredLogEvents()
    }

    func pauseLogPresentation() {
        isLogPresentationPaused = true
    }

    func resumeLogPresentation() async {
        guard isLogPresentationPaused else { return }
        isLogPresentationPaused = false
        pendingLogEventCount = 0
        logEvents = await logBuffer.snapshot(.all).events
        rebuildFilteredLogEvents()
    }

    func saveCurrentKeyword() {
        saveKeyword(logFilter.keyword)
    }

    func saveKeyword(_ keyword: String) {
        keywordStore.save(keyword)
        savedKeywords = keywordStore.keywords
    }

    func removeSavedKeyword(_ keyword: SavedKeyword) {
        keywordStore.remove(keyword.value)
        savedKeywords = keywordStore.keywords
    }

    func exportText(scope: LogExportScope, redact: Bool) -> String {
        let events = scope == .filtered ? filteredLogEvents : logEvents
        return LogExporter.text(events: events, redact: redact)
    }

    func isFavorite(_ app: AppDescriptor) -> Bool {
        appSelectionStore.preferences.favoritePackageNames.contains(app.packageName.value)
    }

    func toggleFavorite(_ app: AppDescriptor) {
        _ = appSelectionStore.toggleFavorite(app.packageName.value)
        refreshAppSections()
    }

    private func startLogCapture(
        for app: AppDescriptor,
        on selectedDevice: DeviceDescriptor
    ) {
        guard let appCatalog, let logSession else { return }
        logCaptureGeneration &+= 1
        let generation = logCaptureGeneration
        logTask = Task { [weak self] in
            await self?.runLogCaptureLoop(
                app: app,
                device: selectedDevice,
                appCatalog: appCatalog,
                logSession: logSession,
                generation: generation
            )
        }
    }

    private func runLogCaptureLoop(
        app: AppDescriptor,
        device: DeviceDescriptor,
        appCatalog: any AppCatalogProtocol,
        logSession: any LogSessionProtocol,
        generation: UInt64
    ) async {
        var historyLoadedPIDs = Set<Int32>()
        var retryAttempt = 0
        let backoffDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]

        while !Task.isCancelled {
            let pids: [Int32]
            do {
                pids = try await appCatalog.resolveProcesses(
                    packageName: app.packageName,
                    on: device
                ).map(\.pid)
            } catch {
                logStreamError = Self.errorCode(error)
                logCaptureState = .stopped
                return
            }

            guard !pids.isEmpty else {
                isLogStreaming = false
                logCaptureState = .waitingForAppLaunch
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            let pidsNeedingHistory = pids.filter { !historyLoadedPIDs.contains($0) }
            if !pidsNeedingHistory.isEmpty {
                logCaptureState = .loadingRecentLogs
                if await loadRecentLogs(on: device, pids: pidsNeedingHistory, logSession: logSession) {
                    historyLoadedPIDs.formUnion(pidsNeedingHistory)
                }
            }

            guard logCaptureGeneration == generation else { return }

            switch await streamLogs(
                app: app,
                device: device,
                pids: pids,
                appCatalog: appCatalog,
                logSession: logSession,
                generation: generation
            ) {
            case .streamEnded:
                retryAttempt = 0
                isLogStreaming = false
                logCaptureState = .waitingForAppLaunch
                try? await Task.sleep(for: .milliseconds(500))
            case .pidsChanged:
                retryAttempt = 0
                isLogStreaming = false
            case .cancelled:
                return
            case .failed(let code):
                await flushPendingLogEvents()
                await monitorDeviceConnection()
                guard logCaptureGeneration == generation, phase == .viewingLogs else { return }
                isLogStreaming = false
                logCaptureState = .waitingForAppLaunch
                logStreamError = code
                let delay = backoffDelays[min(retryAttempt, backoffDelays.count - 1)]
                retryAttempt += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard logCaptureGeneration == generation else { return }
                logStreamError = nil
            }
        }
    }

    private func loadRecentLogs(
        on device: DeviceDescriptor,
        pids: [Int32],
        logSession: any LogSessionProtocol
    ) async -> Bool {
        let historyLines = captureSettings.historyLines
        guard historyLines > 0 else { return true }
        do {
            let recentEvents = try await logSession.recentEvents(
                on: device,
                pids: pids,
                limit: historyLines
            )
            guard !Task.isCancelled else { return false }
            for event in recentEvents {
                await appendLogEvent(event)
            }
            await flushPendingLogEvents()
            return true
        } catch {
            logHistoryError = Self.errorCode(error)
            return false
        }
    }

    private func streamLogs(
        app: AppDescriptor,
        device: DeviceDescriptor,
        pids: [Int32],
        appCatalog: any AppCatalogProtocol,
        logSession: any LogSessionProtocol,
        generation: UInt64
    ) async -> LogStreamOutcome {
        isLogStreaming = true
        logCaptureState = .followingLiveLogs

        return await withTaskGroup(of: LogStreamOutcome.self) { group -> LogStreamOutcome in
            group.addTask { [weak self] in
                do {
                    let stream = try logSession.events(on: device, pids: pids, startingID: 1)
                    for try await event in stream {
                        try Task.checkCancellation()
                        await self?.appendStreamEvent(event, generation: generation)
                    }
                    return .streamEnded
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed(Self.errorCode(error))
                }
            }

            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if Task.isCancelled { return .cancelled }
                    let freshPIDs: [Int32]
                    do {
                        freshPIDs = try await appCatalog.resolveProcesses(
                            packageName: app.packageName,
                            on: device
                        ).map(\.pid)
                    } catch {
                        continue
                    }
                    if Task.isCancelled { return .cancelled }
                    if Set(freshPIDs) != Set(pids) {
                        return .pidsChanged
                    }
                }
                return .cancelled
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    private func resolveInstaller() throws -> any ADBInstalling {
        if let adbInstaller { return adbInstaller }
        let installer = try environment.makeADBInstaller()
        adbInstaller = installer
        return installer
    }

    private func resolveDeviceService(for installation: ADBInstallation) {
        if deviceService == nil {
            deviceService = environment.makeDeviceService(installation)
        }
        if appCatalog == nil {
            appCatalog = environment.makeAppCatalog(installation)
        }
        if logSession == nil {
            logSession = environment.makeLogSession(installation)
        }
        if adbToolService == nil {
            adbToolService = ADBToolService(adb: ADBRuntime(
                executableURL: installation.executableURL,
                runner: FoundationProcessRunner()
            ))
        }
        if scrcpyManager == nil {
            scrcpyManager = try? ScrcpyManager.production(
                adbURL: installation.executableURL
            )
        }
        if wirelessService == nil {
            wirelessService = environment.makeWirelessService(installation)
        }
    }

    private func startDeviceMonitoringIfNeeded() {
        guard deviceMonitorTask == nil else { return }
        deviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.devicePollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.monitorDeviceConnection()
            }
        }
    }

    private func applyDeviceConnection(_ state: DeviceConnectionState) {
        deviceConnection = state
        switch state {
        case .connected(let device):
            selectedDevice = device
            if phase == .selectingDevice {
                // 仅首次发现（刷新自动连接）时更新"最近使用"；
                // 监控轮询期间的重复 `.connected` 不再覆盖记录。
                recordRecentDevice(device)
                phase = defaultDevicePhase
                Task { await loadApps() }
            }
        case .scanning:
            break
        case .noDevice, .authorizationRequired, .selectionRequired, .offline, .failed:
            guard phase == .selectingApp || phase == .toolbox || phase == .viewingLogs else { return }
            logTask?.cancel()
            logTask = nil
            isLogStreaming = false
            logCaptureState = .stopped
            logStreamError = nil
            logHistoryError = nil
            selectedApp = nil
            phase = .selectingDevice
        }
    }

    /// 应用监控轮询结果。与用户主动刷新不同，断连需要连续多次确认，
    /// 避免一次瞬态 `.failed` / `.noDevice` 就把用户从日志或工具箱踢回设备选择页。
    private func applyMonitoredConnection(_ state: DeviceConnectionState) {
        switch state {
        case .connected(let device):
            // 刚切换到无线后，短暂忽略其它设备（如仍插着的 USB）的抢占覆盖。
            if let preferred = preferredWirelessSerial,
               let until = preferredWirelessUntil,
               ContinuousClock.now < until {
                if device.serial.value == preferred {
                    preferredWirelessSerial = nil
                    preferredWirelessUntil = nil
                } else {
                    return
                }
            }
            consecutiveDisconnectCount = 0
            applyDeviceConnection(state)
        case .scanning:
            return
        case .selectionRequired(let devices):
            // 多台在线设备：只要当前选中的设备仍在候选列表中，就维持会话，
            // 不把新增接入的设备当作断连。
            if isInActiveSession,
               let selectedDevice,
               devices.contains(where: { $0.serial == selectedDevice.serial }) {
                consecutiveDisconnectCount = 0
                deviceConnection = .connected(selectedDevice)
                return
            }
            applyDisconnection(state)
        case .noDevice, .authorizationRequired, .offline, .failed:
            applyDisconnection(state)
        }
    }

    private func applyDisconnection(_ state: DeviceConnectionState) {
        guard isInActiveSession else {
            applyDeviceConnection(state)
            return
        }
        // 连接切换保护窗口内：忽略 .noDevice/.offline 等瞬态断连，避免 adbd 重启时误跳转设备选择页。
        if isSwitchProtectionActive {
            consecutiveDisconnectCount = 0
            return
        }
        consecutiveDisconnectCount += 1
        guard consecutiveDisconnectCount >= Self.disconnectConfirmationThreshold else { return }
        applyDeviceConnection(state)
    }

    private var isSwitchProtectionActive: Bool {
        guard let deadline = switchProtectionDeadline else { return false }
        return ContinuousClock.now < deadline
    }

    func beginSwitchProtection(duration: Duration = .seconds(20)) {
        switchProtectionDeadline = ContinuousClock.now.advanced(by: duration)
    }

    func endSwitchProtection() {
        switchProtectionDeadline = nil
    }

    private var isInActiveSession: Bool {
        phase == .selectingApp || phase == .toolbox || phase == .viewingLogs
    }

    // MARK: - 无线调试

    /// 记录当前已知设备序列号，供配对后识别新增设备。
    func snapshotKnownDeviceSerials() async {
        guard let deviceService else { return }
        if let state = try? await deviceService.refresh() {
            knownDeviceSerials = Set(Self.devices(in: state).map(\.id))
        }
    }

    /// 无线页配对/连接成功后调用：刷新设备并切换到本次新增的无线设备。
    /// 返回是否实际发现并切换到了新设备；调用方据此决定是否继续轮询等待。
    @discardableResult
    func adoptWirelessDevice() async -> Bool {
        guard let deviceService else { return false }
        do {
            let state = try await deviceService.refresh()
            let devices = Self.devices(in: state)
            // 只接受配对前不存在的设备，避免多设备时误切到其它无线设备，
            // 也避免在 mDNS 自动连接尚未完成时把旧设备误判为"已连接无线"。
            guard let newDevice = devices.first(where: { !knownDeviceSerials.contains($0.id) }) else {
                return false
            }
            switchToDevice(newDevice)
            return true
        } catch {
            return false
        }
    }

    private static func devices(in state: DeviceConnectionState) -> [DeviceDescriptor] {
        switch state {
        case .connected(let device): [device]
        case .selectionRequired(let devices): devices
        case .scanning, .noDevice, .authorizationRequired, .offline, .failed: []
        }
    }

    /// 切换到指定设备；若正在查看日志，则在保留筛选与暂停状态的前提下重载当前应用日志。
    func switchToDevice(_ device: DeviceDescriptor) {
        selectedDevice = device
        deviceConnection = .connected(device)
        consecutiveDisconnectCount = 0
        recordRecentDevice(device)
        switch phase {
        case .selectingDevice:
            phase = defaultDevicePhase
            Task { await loadApps() }
        case .viewingLogs:
            if let app = selectedApp {
                migrateLogSession(to: device, app: app)
            }
        case .selectingApp, .toolbox:
            // 设备序列号已变化，重新加载应用列表。
            Task { await loadApps() }
        case .preparingADB:
            break
        }
    }

    private func migrateLogSession(to device: DeviceDescriptor, app: AppDescriptor) {
        let paused = isLogPresentationPaused
        logTask?.cancel()
        logTask = nil
        logCaptureGeneration &+= 1
        resetLogStorage(resetEventIDs: true)
        isLogPresentationPaused = paused
        isLogStreaming = false
        logStreamError = nil
        logHistoryError = nil
        logCaptureState = .waitingForAppLaunch
        startLogCapture(for: app, on: device)
    }

    func disconnectWirelessDevice() async {
        guard let wirelessService,
              let device = selectedDevice,
              device.transport.isWireless else { return }
        preferredWirelessSerial = nil
        preferredWirelessUntil = nil
        try? await wirelessService.disconnect(address: device.serial.value)
        await monitorDeviceConnection()
    }

    func disconnectAllWirelessDevices() async {
        guard let wirelessService else { return }
        try? await wirelessService.disconnect(address: nil)
        await monitorDeviceConnection()
    }

    func restoreUSB() async {
        guard let wirelessService, let device = selectedDevice else { return }
        preferredWirelessSerial = nil
        preferredWirelessUntil = nil
        beginSwitchProtection()
        defer { endSwitchProtection() }
        try? await wirelessService.restoreUSB(serial: device.serial)
        await monitorDeviceConnection()
    }

    func restartADBServer() async {
        guard let wirelessService else { return }
        try? await wirelessService.restartServer()
        await monitorDeviceConnection()
    }

    /// 一键把当前 USB 设备切换为无线：获取 Wi-Fi IP → tcpip → connect（带重试）→ 切换会话。
    /// 返回是否已切换成功；失败抛错由调用方展示。wifiIP 为空时自动探测。
    @discardableResult
    func switchUSBToWireless(port: Int = 5_555, wifiIP: String? = nil) async throws -> Bool {
        guard let wirelessService,
              let device = selectedDevice,
              device.transport == .usb else {
            throw WirelessDebugError.usbDeviceRequired
        }
        let ip: String
        if let wifiIP, !wifiIP.isEmpty {
            ip = wifiIP
        } else {
            guard let detected = try await wirelessService.wifiIPAddress(serial: device.serial), !detected.isEmpty else {
                throw WirelessDebugError.wifiIPUnavailable
            }
            ip = detected
        }
        // 进入切换流程即开启保护窗口，adbd 重启导致的短暂 noDevice 不会误跳转。
        beginSwitchProtection(duration: .seconds(30))
        defer { endSwitchProtection() }

        // tcpip 会让 adbd 异步重启、USB 短暂消失；失败不致命（设备可能已在 TCP 模式）。
        try? await wirelessService.enableTCPIP(serial: device.serial, port: port)

        let endpoint = try ADBEndpoint(host: ip, port: port)
        // adbd 重启完成前 connect 会失败，带退避重试直到成功或超时。
        await connectWithRetry(service: wirelessService, endpoint: endpoint)

        // 轮询等待序列号为 ip:port 的无线设备出现并切换（精确匹配，重连场景也可靠）。
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            if await adoptDeviceAndPin(withSerial: endpoint.argument) { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return await adoptDeviceAndPin(withSerial: endpoint.argument)
    }

    /// 按序列号精确选中设备并切换（USB→无线用，序列号即 ip:port）。
    @discardableResult
    func adoptDevice(withSerial serial: String) async -> Bool {
        guard let deviceService else { return false }
        guard let state = try? await deviceService.refresh() else { return false }
        let devices = Self.devices(in: state)
        guard let device = devices.first(where: { $0.id == serial }) else { return false }
        switchToDevice(device)
        return true
    }

    /// 切换成功后短暂固定该无线设备，避免被仍在线的 USB 设备抢占覆盖。
    private func adoptDeviceAndPin(withSerial serial: String) async -> Bool {
        guard await adoptDevice(withSerial: serial) else { return false }
        preferredWirelessSerial = serial
        preferredWirelessUntil = ContinuousClock.now.advanced(by: .seconds(15))
        return true
    }

    /// 带退避重试 connect，容忍 adbd 重启窗口。
    private func connectWithRetry(
        service: any WirelessDebugServiceProtocol,
        endpoint: ADBEndpoint,
        timeout: Duration = .seconds(12)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if (try? await service.connect(endpoint: endpoint)) != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    // MARK: - 启动恢复

    /// 后台启动恢复任务：无参数时恢复最近的无线 TCP/IP 记录，有参数时恢复指定记录。
    /// 每次启动都会推进 generation，旧任务即使随后被取消执行清理，也不会覆盖新任务的状态。
    func startRecovery(for record: RecentDeviceConnection?) {
        recoveryTask?.cancel()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryTask = Task { [weak self] in
            await self?.runRecovery(record: record, generation: generation)
        }
    }

    func cancelRecovery() async {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryGeneration &+= 1
        endSwitchProtection()
        connectionRecoveryState = .completed
        await refreshDevices()
    }

    private func runRecovery(record: RecentDeviceConnection?, generation: UInt64) async {
        guard generation == recoveryGeneration else { return }
        connectionRecoveryState = .discoveringADBDevices
        let target: RecentDeviceConnection?
        if let record {
            target = record
        } else {
            target = recentDeviceConnections.first(where: {
                $0.transport == .wirelessTCPIP && $0.autoRestoreEnabled && $0.tcpIPAddress != nil
            })
        }
        guard let target,
              let address = target.tcpIPAddress,
              let endpoint = WirelessDebugService.parseAddress(address) else {
            guard generation == recoveryGeneration else { return }
            connectionRecoveryState = .completed
            return
        }
        guard generation == recoveryGeneration else { return }
        connectionRecoveryState = .reconnectingSavedTCPIP(address)
        beginSwitchProtection(duration: .seconds(8))
        defer {
            if generation == recoveryGeneration {
                endSwitchProtection()
                connectionRecoveryState = .completed
            }
        }
        await connectAndAdopt(endpoint: endpoint)
    }

    private func connectAndAdopt(endpoint: ADBEndpoint) async {
        guard let wirelessService else { return }
        try? await wirelessService.connect(endpoint: endpoint)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while clock.now < deadline {
            if Task.isCancelled { return }
            if await adoptDevice(withSerial: endpoint.argument) { return }
            try? await Task.sleep(for: .seconds(1))
        }
        if Task.isCancelled { return }
        _ = await adoptDevice(withSerial: endpoint.argument)
    }

    func removeRecentDevice(serial: String) {
        recentDeviceStore.remove(serial: serial)
        recentDeviceConnections = recentDeviceStore.records
    }

    func setAutoRestore(_ enabled: Bool, serial: String) {
        recentDeviceStore.setAutoRestore(enabled, serial: serial)
        recentDeviceConnections = recentDeviceStore.records
    }

    private func appendStreamEvent(_ event: LogEvent, generation: UInt64) async {
        guard logCaptureGeneration == generation else { return }
        await appendLogEvent(event)
    }

    private func appendLogEvent(_ event: LogEvent) async {
        let normalized = LogEvent(
            id: nextLogEventID,
            deviceTimestamp: event.deviceTimestamp,
            receivedAt: event.receivedAt,
            pid: event.pid,
            tid: event.tid,
            priority: event.priority,
            androidTag: event.androidTag,
            businessTag: event.businessTag,
            message: event.message,
            rawText: event.rawText,
            parseStatus: event.parseStatus,
            packageName: event.packageName,
            processName: event.processName
        )
        nextLogEventID &+= 1
        pendingLogEvents.append(normalized)
        pendingLogTextBytes += normalized.message.utf8.count + normalized.rawText.utf8.count
        if pendingLogEvents.count >= 500 || pendingLogTextBytes >= 1_024 * 1_024 {
            await flushPendingLogEvents()
        } else {
            scheduleLogFlush()
        }
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flushPendingLogEvents()
        }
    }

    private func flushPendingLogEvents() async {
        logFlushTask = nil
        guard !pendingLogEvents.isEmpty else { return }
        let events = pendingLogEvents
        pendingLogEvents.removeAll(keepingCapacity: true)
        pendingLogTextBytes = 0
        let eviction = await logBuffer.append(events)
        if isLogPresentationPaused {
            pendingLogEventCount += events.count
        } else if eviction.evictedEvents == 0 {
            logEvents.append(contentsOf: events)
            if logFilter.levels.isEmpty && !logFilter.hasKeyword {
                filteredLogEvents.append(contentsOf: events)
            } else {
                // apply 只计算一次关键词分组，避免每事件重编译正则。
                filteredLogEvents.append(contentsOf: logFilter.apply(events))
            }
        } else {
            logEvents = await logBuffer.snapshot(.all).events
            filteredLogEvents = logFilter.apply(logEvents)
        }
    }

    private func resetLogStorage(resetEventIDs: Bool = true) {
        logFlushTask?.cancel()
        logFlushTask = nil
        pendingLogEvents.removeAll(keepingCapacity: false)
        pendingLogTextBytes = 0
        logBuffer = LogRingBuffer(limits: cacheLimitsOverride ?? captureSettings.cacheLimits)
        logEvents = []
        filteredLogEvents = []
        if resetEventIDs { nextLogEventID = 1 }
        isLogPresentationPaused = false
        pendingLogEventCount = 0
    }

    private func rebuildFilteredLogEvents() {
        filteredLogEvents = logFilter.apply(logEvents)
    }


    private func refreshAppSections() {
        let appsByPackage = Dictionary(uniqueKeysWithValues: availableApps.map { ($0.packageName.value, $0) })
        let preferences = appSelectionStore.preferences
        recentApps = preferences.recentPackageNames.compactMap { appsByPackage[$0] }
        favoriteApps = preferences.favoritePackageNames.compactMap { appsByPackage[$0] }
    }

    private nonisolated static func errorCode(_ error: Error) -> String {
        switch error {
        case let error as ADBError:
            switch error {
            case .commandFailed(let exitCode, _):
                return "adb_error_\(exitCode)"
            }
        case let error as ProcessRunnerError:
            switch error {
            case .timedOut: return "process_timeout"
            case .outputBufferOverflow: return "output_buffer_overflow"
            }
        case let error as LogSessionError:
            switch error {
            case .processExitedNonZero(let exitCode, _):
                return "logcat_exited_\(exitCode)"
            }
        case let error as ADBInstallerError:
            return error.code
        case let error as ADBValidationError:
            switch error {
            case .invalidEndpoint: return "invalid_endpoint"
            case .invalidDeviceSerial: return "invalid_device_serial"
            case .invalidPackageName: return "invalid_package_name"
            case .invalidPairingCode: return "invalid_pairing_code"
            case .invalidDeepLink: return "invalid_deep_link"
            case .invalidActivityComponent: return "invalid_activity_component"
            case .invalidInputText: return "invalid_input_text"
            case .invalidJSON: return "invalid_json"
            case .invalidAPK: return "invalid_apk"
            case .invalidScreenshot: return "invalid_screenshot"
            }
        default:
            return "unexpected_error"
        }
    }

    private var isFailed: Bool {
        guard case .failed = adbPreparation else { return false }
        return true
    }
}
