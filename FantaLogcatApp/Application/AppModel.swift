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
    @Published private(set) var logEvents: [LogEvent] = []
    @Published private(set) var isLogStreaming = false
    @Published private(set) var logStreamError: String?

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
    private var deviceService: (any DeviceServiceProtocol)?
    private var appCatalog: (any AppCatalogProtocol)?
    private var logSession: (any LogSessionProtocol)?
    private var logTask: Task<Void, Never>?
    private var logFlushTask: Task<Void, Never>?
    private let cacheLimits: CacheLimits
    private var logBuffer: LogRingBuffer
    private var pendingLogEvents: [LogEvent] = []
    private var pendingLogTextBytes = 0
    private let appSelectionStore: any AppSelectionStoreProtocol
    private var retryOperation: RetryOperation = .check

    init(environment: AppEnvironment, cacheLimits: CacheLimits = .default) {
        self.environment = environment
        self.cacheLimits = cacheLimits
        logBuffer = LogRingBuffer(limits: cacheLimits)
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
            deviceConnection = state
            if case .connected(let device) = state {
                selectedDevice = device
                phase = .selectingApp
                await loadApps()
            }
        } catch {
            deviceConnection = .failed(errorCode(error))
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
        guard phase == .selectingApp, let selectedDevice else { return }
        guard let appCatalog else { return }
        do {
            availableApps = try await appCatalog.listApps(on: selectedDevice)
            refreshAppSections()
        }
        catch { availableApps = [] }
    }

    func selectApp(_ app: AppDescriptor) {
        guard let selectedDevice, let appCatalog, let logSession else { return }
        logTask?.cancel()
        appSelectionStore.recordRecent(app.packageName.value)
        refreshAppSections()
        selectedApp = app
        resetLogStorage()
        logStreamError = nil
        isLogStreaming = true
        phase = .viewingLogs
        logTask = Task { [weak self] in
            let pids = (try? await appCatalog.resolveProcesses(
                packageName: app.packageName,
                on: selectedDevice
            ))?.map(\.pid) ?? []
            do {
                let stream = try logSession.events(on: selectedDevice, pids: pids)
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    await self?.appendLogEvent(event)
                }
                await self?.flushPendingLogEvents()
                self?.isLogStreaming = false
            } catch is CancellationError {
                return
            } catch {
                await self?.flushPendingLogEvents()
                self?.logStreamError = self?.errorCode(error) ?? "unexpected_error"
                self?.isLogStreaming = false
            }
        }
    }

    func returnToAppSelection() {
        logTask?.cancel()
        logTask = nil
        resetLogStorage()
        isLogStreaming = false
        logStreamError = nil
        phase = .selectingApp
    }

    func clearLogs() {
        resetLogStorage()
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

    private func appendLogEvent(_ event: LogEvent) async {
        pendingLogEvents.append(event)
        pendingLogTextBytes += event.message.utf8.count + event.rawText.utf8.count
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
        logEvents = await logBuffer.snapshot(.all).events
    }

    private func resetLogStorage() {
        logFlushTask?.cancel()
        logFlushTask = nil
        pendingLogEvents.removeAll(keepingCapacity: false)
        pendingLogTextBytes = 0
        logBuffer = LogRingBuffer(limits: cacheLimits)
        logEvents = []
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
