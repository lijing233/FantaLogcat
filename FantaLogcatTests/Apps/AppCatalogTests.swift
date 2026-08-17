import Foundation
import XCTest
@testable import FantaLogcat

final class AppCatalogTests: XCTestCase {
    func testConfiguredAppGetsFriendlyPresentationAndUnknownAppDoesNotInventMetadata() async throws {
        let catalog = AppCatalog(
            adb: StubAppADB(
                packages: ["com.game.tile", "com.unknown"],
                processOutput: ""
            ),
            presets: [
                AppPreset(
                    id: "team.tile",
                    packageName: try AndroidPackageName("com.game.tile"),
                    displayName: "Tile Match",
                    symbolName: "gamecontroller.fill",
                    favoriteOrder: 0,
                    group: "Games"
                )
            ]
        )

        let apps = try await catalog.listApps(on: DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        ))

        XCTAssertEqual(apps.map(\.presentation.displayName), ["Tile Match", "com.unknown"])
        XCTAssertEqual(apps[0].presentation.provenance, .preset)
        XCTAssertEqual(apps[1].presentation.provenance, .generic)
    }

    func testPIDResolutionIncludesPackageChildProcesses() async throws {
        let catalog = AppCatalog(adb: StubAppADB(
            packages: [],
            processOutput: "42 com.game.tile\n43 com.game.tile:ads\n44 com.other\n"
        ))
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        let processes = try await catalog.resolveProcesses(
            packageName: try AndroidPackageName("com.game.tile"),
            on: device
        )

        XCTAssertEqual(processes.map(\.pid), [42, 43])
    }

    func testPIDResolutionFallsBackToPidOfWhenPSIsUnavailable() async throws {
        let catalog = AppCatalog(adb: StubAppADB(
            packages: [],
            processOutput: "",
            processError: ADBError.commandFailed(exitCode: 1, stderrSummary: "bad -o"),
            pidOfOutput: "84 42\n"
        ))
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        let processes = try await catalog.resolveProcesses(
            packageName: try AndroidPackageName("com.game.tile"),
            on: device
        )

        XCTAssertEqual(processes.map(\.pid), [42, 84])
        XCTAssertEqual(processes.map(\.name), ["com.game.tile", "com.game.tile"])
    }

    func testGenericAppUsesPackageNameWithoutExtraADBLabelLookup() async throws {
        let catalog = AppCatalog(adb: StubAppADB(
            packages: ["com.game.tile"],
            processOutput: "",
            applicationLabels: ["com.game.tile": "Tile Match"]
        ))
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        let apps = try await catalog.listApps(on: device)

        XCTAssertEqual(apps.first?.presentation.displayName, "com.game.tile")
    }
}

private struct StubAppADB: ADBRuntimeProtocol {
    let packages: [String]
    let processOutput: String
    let processError: Error?
    let pidOfOutput: String
    let applicationLabels: [String: String]

    init(
        packages: [String],
        processOutput: String,
        processError: Error? = nil,
        pidOfOutput: String = "",
        applicationLabels: [String: String] = [:]
    ) {
        self.packages = packages
        self.processOutput = processOutput
        self.processError = processError
        self.pidOfOutput = pidOfOutput
        self.applicationLabels = applicationLabels
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        switch command {
        case .listThirdPartyPackages:
            return .success(stdout: packages.map { "package:\($0)" }.joined(separator: "\n"))
        case .resolvePIDs:
            if let processError { throw processError }
            return .success(stdout: processOutput)
        case .pidOf:
            return .success(stdout: pidOfOutput)
        case .applicationLabel(_, let packageName):
            return .success(stdout: applicationLabels[packageName.value].map { "application-label:'\($0)'" } ?? "")
        default:
            return .success()
        }
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
