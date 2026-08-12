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
}

private struct StubAppADB: ADBRuntimeProtocol {
    let packages: [String]
    let processOutput: String

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        switch command {
        case .listThirdPartyPackages:
            return .success(stdout: packages.map { "package:\($0)" }.joined(separator: "\n"))
        case .resolvePIDs:
            return .success(stdout: processOutput)
        default:
            return .success()
        }
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
