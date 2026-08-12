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
    @Published private(set) var logEvents: [LogEvent] = []
    @Published private(set) var isLogStreaming = false
    @Published private(set) var logStreamError: String?

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
    private var deviceService: (any DeviceServiceProtocol)?
    private var appCatalog: (any AppCatalogProtocol)?
    private var logSession: (any LogSessionProtocol)?
    private var logTask: Task<Void, Never>?
    private var retryOperation: RetryOperation = .check

    init(environment: AppEnvironment) {
        self.environment = environment
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
        do { availableApps = try await appCatalog.listApps(on: selectedDevice) }
        catch { availableApps = [] }
    }

    func selectApp(_ app: AppDescriptor) {
        guard let selectedDevice, let appCatalog, let logSession else { return }
        logTask?.cancel()
        selectedApp = app
        logEvents = []
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
                    self?.appendLogEvent(event)
                }
                self?.isLogStreaming = false
            } catch is CancellationError {
                return
            } catch {
                self?.logStreamError = self?.errorCode(error) ?? "unexpected_error"
                self?.isLogStreaming = false
            }
        }
    }

    func returnToAppSelection() {
        logTask?.cancel()
        logTask = nil
        isLogStreaming = false
        logStreamError = nil
        phase = .selectingApp
    }

    func clearLogs() {
        logEvents = []
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

    private func appendLogEvent(_ event: LogEvent) {
        logEvents.append(event)
        if logEvents.count > 100_000 {
            logEvents.removeFirst(1_000)
        }
    }

    private func errorCode(_ error: Error) -> String {
        (error as? ADBInstallerError)?.code ?? "unexpected_error"
    }

    private var isFailed: Bool {
        guard case .failed = adbPreparation else { return false }
        return true
    }
}
