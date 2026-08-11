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

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?
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
            case .ready:
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
            _ = try await installer.install(acceptingLicense: true)
            phase = .selectingDevice
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

    private func resolveInstaller() throws -> any ADBInstalling {
        if let adbInstaller { return adbInstaller }
        let installer = try environment.makeADBInstaller()
        adbInstaller = installer
        return installer
    }

    private func errorCode(_ error: Error) -> String {
        (error as? ADBInstallerError)?.code ?? "unexpected_error"
    }

    private var isFailed: Bool {
        guard case .failed = adbPreparation else { return false }
        return true
    }
}
