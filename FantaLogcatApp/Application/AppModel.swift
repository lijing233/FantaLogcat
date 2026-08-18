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

    private(set) var adbToolService: ADBToolService?
    private(set) var scrcpyManager: ScrcpyManager?

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
    private let cacheLimitsOverride: CacheLimits?
    private var logBuffer: LogRingBuffer
    private var nextLogEventID: UInt64 = 1
    private var pendingLogEvents: [LogEvent] = []
    private var pendingLogTextBytes = 0
    private let keywordStore: any LogKeywordStoreProtocol
    private let appSelectionStore: any AppSelectionStoreProtocol
    private let settingsStore: any AppSettingsStore
    private var retryOperation: RetryOperation = .check
    private var consecutiveDisconnectCount = 0

    private static let devicePollInterval = Duration.seconds(2)
    private static let disconnectConfirmationThreshold = 2

    init(
        environment: AppEnvironment,
        cacheLimits: CacheLimits? = nil,
        keywordStore: any LogKeywordStoreProtocol = UserDefaultsLogKeywordStore(),
        settingsStore: any AppSettingsStore = UserDefaultsAppSettingsStore()
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
        case .connected:
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
        consecutiveDisconnectCount += 1
        guard consecutiveDisconnectCount >= Self.disconnectConfirmationThreshold else { return }
        applyDeviceConnection(state)
    }

    private var isInActiveSession: Bool {
        phase == .selectingApp || phase == .toolbox || phase == .viewingLogs
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
