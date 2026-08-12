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

    func testRetryAfterPreparationFailureChecksAgainWithoutInstalling() async {
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { throw ADBInstallerError.fileOperationFailed },
            makeDeviceService: { _ in AppModelDeviceService(state: .noDevice) },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.retryADB()

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .failed("file_operation_failed"))
    }

    func testRetryAfterAuthorizedInstallFailureRetriesInstallation() async {
        let installer = AppModelInstaller(initialState: .notInstalled)
        let model = AppModel(environment: .test(installer: installer))
        await model.prepareADB()

        await model.installADB()
        await model.retryADB()

        let installCalls = await installer.installCalls
        XCTAssertEqual(installCalls, 2)
        XCTAssertEqual(model.adbPreparation, .failed("checksum_mismatch"))
    }

    func testSingleDeviceAutomaticallyAdvancesToApplicationSelection() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try! ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let model = AppModel(environment: .test(
            installer: AppModelInstaller(initialState: .ready(installation)),
            deviceService: AppModelDeviceService(state: .connected(device))
        ))

        await model.prepareADB()
        await model.refreshDevices()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }
}

private actor AppModelInstaller: ADBInstalling {
    let initialState: ADBInstallationState
    let installResult: Result<ADBInstallation, Error>
    private(set) var installCalls = 0

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
        installCalls += 1
        return try installResult.get()
    }

    func rollback() throws -> ADBInstallation {
        throw ADBInstallerError.noRollbackAvailable
    }
}

private actor AppModelDeviceService: DeviceServiceProtocol {
    let state: DeviceConnectionState

    init(state: DeviceConnectionState) {
        self.state = state
    }

    func refresh() async throws -> DeviceConnectionState { state }
}

private actor AppModelAppCatalog: AppCatalogProtocol {
    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor] { [] }
    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor] { [] }
}
