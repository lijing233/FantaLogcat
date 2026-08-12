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

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
    private var deviceService: (any DeviceServiceProtocol)?
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
    }

    private func errorCode(_ error: Error) -> String {
        (error as? ADBInstallerError)?.code ?? "unexpected_error"
    }

    private var isFailed: Bool {
        guard case .failed = adbPreparation else { return false }
        return true
    }
}
