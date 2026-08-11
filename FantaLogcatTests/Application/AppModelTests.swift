import Foundation
import XCTest
@testable import FantaLogcat

@MainActor
final class AppModelTests: XCTestCase {
    func testNewModelStartsInPreparingADBPhase() {
        let model = AppModel(environment: .test())

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .checking)
    }

    func testMissingADBShowsLicenseActionInsteadOfInfiniteProgress() async {
        let installer = AppModelInstaller(initialState: .notInstalled)
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .licenseRequired)
    }

    func testReadyADBAdvancesToDeviceSelection() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let installer = AppModelInstaller(initialState: .ready(installation))
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()

        XCTAssertEqual(model.phase, .selectingDevice)
    }

    func testInstallingADBSucceedsAndAdvances() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let installer = AppModelInstaller(
            initialState: .notInstalled,
            installResult: .success(installation)
        )
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()
        await model.installADB()

        XCTAssertEqual(model.phase, .selectingDevice)
    }
}

private actor AppModelInstaller: ADBInstalling {
    let initialState: ADBInstallationState
    let installResult: Result<ADBInstallation, Error>

    init(
        initialState: ADBInstallationState,
        installResult: Result<ADBInstallation, Error> = .failure(ADBInstallerError.checksumMismatch)
    ) {
        self.initialState = initialState
        self.installResult = installResult
    }

    func state() -> ADBInstallationState {
        initialState
    }

    func install(acceptingLicense: Bool) throws -> ADBInstallation {
        try installResult.get()
    }

    func rollback() throws -> ADBInstallation {
        throw ADBInstallerError.noRollbackAvailable
    }
}
