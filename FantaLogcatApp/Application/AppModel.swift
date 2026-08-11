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
    @Published private(set) var phase: AppPhase = .preparingADB
    @Published private(set) var adbPreparation: ADBPreparationState = .checking

    let environment: AppEnvironment
    private var adbInstaller: (any ADBInstalling)?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func prepareADB() async {
        guard phase == .preparingADB else { return }
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
        guard phase == .preparingADB else { return }
        adbPreparation = .installing
        do {
            let installer = try resolveInstaller()
            _ = try await installer.install(acceptingLicense: true)
            phase = .selectingDevice
        } catch {
            adbPreparation = .failed(errorCode(error))
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
}
