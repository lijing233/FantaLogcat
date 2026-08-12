import SwiftUI

enum AppPhase: Equatable {
    case preparingADB
    case selectingDevice
    case selectingApp
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
    @Published private(set) var isLogStreaming = false
    @Published private(set) var logStreamError: String?
    @Published private(set) var logHistoryError: String?
    @Published private(set) var logCaptureState: LogCaptureState = .stopped
    @Published private(set) var logFilter = LogFilter()
    @Published private(set) var savedKeywords: [SavedKeyword] = []
    @Published private(set) var isLogPresentationPaused = false
    @Published private(set) var pendingLogEventCount = 0
    @Published var isShowingSettings = false
    @Published private(set) var language: AppLanguage
    @Published private(set) var captureSettings: LogCaptureSettings

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
    private var deviceService: (any DeviceServiceProtocol)?
    private var appCatalog: (any AppCatalogProtocol)?
    private var logSession: (any LogSessionProtocol)?
    private var logTask: Task<Void, Never>?
    private var logFlushTask: Task<Void, Never>?
    private var deviceMonitorTask: Task<Void, Never>?
    private let cacheLimitsOverride: CacheLimits?
    private var logBuffer: LogRingBuffer
    private var nextLogEventID: UInt64 = 1
    private var pendingLogEvents: [LogEvent] = []
    private var pendingLogTextBytes = 0
    private let keywordStore: any LogKeywordStoreProtocol
    private let appSelectionStore: any AppSelectionStoreProtocol
    private var retryOperation: RetryOperation = .check

    init(
        environment: AppEnvironment,
        cacheLimits: CacheLimits? = nil,
        keywordStore: any LogKeywordStoreProtocol = UserDefaultsLogKeywordStore()
    ) {
        let loadedCaptureSettings = LogCaptureSettings.load()
        self.environment = environment
        cacheLimitsOverride = cacheLimits
        captureSettings = loadedCaptureSettings
        logBuffer = LogRingBuffer(limits: cacheLimits ?? loadedCaptureSettings.cacheLimits)
        self.keywordStore = keywordStore
        savedKeywords = keywordStore.keywords
        language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "") ?? .chinese
        appSelectionStore = environment.makeAppSelectionStore()
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
            adbPreparation = .failed(errorCode(error))
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
            adbPreparation = .failed(errorCode(error))
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
            applyDeviceConnection(.failed(errorCode(error)))
            startDeviceMonitoringIfNeeded()
        }
    }

    func monitorDeviceConnection() async {
        guard phase != .preparingADB, let deviceService else { return }
        do {
            applyDeviceConnection(try await deviceService.refresh())
        } catch {
            applyDeviceConnection(.failed(errorCode(error)))
        }
    }

    func selectDevice(_ device: DeviceDescriptor) {
        guard phase == .selectingDevice else { return }
        selectedDevice = device
        deviceConnection = .connected(device)
        phase = .selectingApp
        Task { await loadApps() }
    }

    func loadApps() async {
        guard phase == .selectingApp, let selectedDevice, !isLoadingApps else { return }
        guard let appCatalog else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            availableApps = try await appCatalog.listApps(on: selectedDevice)
            refreshAppSections()
        }
        catch { availableApps = [] }
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.storageKey)
    }

    func copy(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }

    func selectApp(_ app: AppDescriptor) {
        guard let selectedDevice, let appCatalog, let logSession else { return }
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
        logTask = Task { [weak self] in
            while !Task.isCancelled {
                let pids: [Int32]
                do {
                    pids = try await appCatalog.resolveProcesses(
                        packageName: app.packageName,
                        on: selectedDevice
                    ).map(\.pid)
                } catch {
                    self?.logStreamError = self?.errorCode(error) ?? "unexpected_error"
                    self?.logCaptureState = .stopped
                    return
                }

                guard !pids.isEmpty else {
                    self?.isLogStreaming = false
                    self?.logCaptureState = .waitingForAppLaunch
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }

                self?.logCaptureState = .loadingRecentLogs
                do {
                    let historyLines = self?.captureSettings.historyLines ?? 0
                    if historyLines > 0 {
                        let recentEvents = try await logSession.recentEvents(
                            on: selectedDevice,
                            pids: pids,
                            limit: historyLines
                        )
                        guard !Task.isCancelled else { return }
                        for event in recentEvents {
                            await self?.appendLogEvent(event)
                        }
                        await self?.flushPendingLogEvents()
                    }
                } catch {
                    self?.logHistoryError = self?.errorCode(error) ?? "unexpected_error"
                }

                do {
                    self?.isLogStreaming = true
                    self?.logCaptureState = .followingLiveLogs
                    let stream = try logSession.events(on: selectedDevice, pids: pids, startingID: 1)
                    for try await event in stream {
                        guard !Task.isCancelled else { return }
                        await self?.appendLogEvent(event)
                    }
                    await self?.flushPendingLogEvents()
                    self?.isLogStreaming = false
                    self?.logCaptureState = .waitingForAppLaunch
                    try? await Task.sleep(for: .milliseconds(500))
                } catch is CancellationError {
                    return
                } catch {
                    await self?.flushPendingLogEvents()
                    await self?.monitorDeviceConnection()
                    guard self?.phase == .viewingLogs else { return }
                    self?.logStreamError = self?.errorCode(error) ?? "unexpected_error"
                    self?.isLogStreaming = false
                    self?.logCaptureState = .stopped
                    return
                }
            }
        }
    }

    func returnToAppSelection() {
        logTask?.cancel()
        logTask = nil
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

    var filteredLogEvents: [LogEvent] {
        logFilter.apply(logEvents)
    }

    func setLogLevels(_ levels: Set<LogPriority>) {
        logFilter.levels = levels
    }

    func setLogKeyword(_ keyword: String) {
        logFilter.keyword = keyword
    }

    func pauseLogPresentation() {
        isLogPresentationPaused = true
    }

    func resumeLogPresentation() async {
        guard isLogPresentationPaused else { return }
        isLogPresentationPaused = false
        pendingLogEventCount = 0
        logEvents = await logBuffer.snapshot(.all).events
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

    func setCaptureSettings(_ settings: LogCaptureSettings) {
        captureSettings = settings.normalized
        captureSettings.save()
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
    }

    private func startDeviceMonitoringIfNeeded() {
        guard deviceMonitorTask == nil else { return }
        deviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
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
                phase = .selectingApp
                Task { await loadApps() }
            }
        case .scanning:
            break
        case .noDevice, .authorizationRequired, .selectionRequired, .offline, .failed:
            guard phase == .selectingApp || phase == .viewingLogs else { return }
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
        _ = await logBuffer.append(events)
        if isLogPresentationPaused {
            pendingLogEventCount += events.count
        } else {
            logEvents = await logBuffer.snapshot(.all).events
        }
    }

    private func resetLogStorage(resetEventIDs: Bool = true) {
        logFlushTask?.cancel()
        logFlushTask = nil
        pendingLogEvents.removeAll(keepingCapacity: false)
        pendingLogTextBytes = 0
        logBuffer = LogRingBuffer(limits: cacheLimitsOverride ?? captureSettings.cacheLimits)
        logEvents = []
        if resetEventIDs { nextLogEventID = 1 }
        isLogPresentationPaused = false
        pendingLogEventCount = 0
    }

    private func refreshAppSections() {
        let appsByPackage = Dictionary(uniqueKeysWithValues: availableApps.map { ($0.packageName.value, $0) })
        let preferences = appSelectionStore.preferences
        recentApps = preferences.recentPackageNames.compactMap { appsByPackage[$0] }
        favoriteApps = preferences.favoritePackageNames.compactMap { appsByPackage[$0] }
    }

    private func errorCode(_ error: Error) -> String {
        (error as? ADBInstallerError)?.code ?? "unexpected_error"
    }

    private var isFailed: Bool {
        guard case .failed = adbPreparation else { return false }
        return true
    }
}
