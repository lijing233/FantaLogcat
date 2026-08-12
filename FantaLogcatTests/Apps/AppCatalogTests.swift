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

    func testGenericAppUsesAndroidApplicationLabel() async throws {
        let catalog = AppCatalog(adb: StubAppADB(
            packages: ["com.game.tile"],
            processOutput: "",
            applicationLabels: ["com.game.tile": "Tile Match"]
        ))
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        let apps = try await catalog.listApps(on: device)

        XCTAssertEqual(apps.first?.presentation.displayName, "Tile Match")
    }

    func testApplicationLabelLookupsUseAtMostFourConcurrentADBCommands() async throws {
        let packages = (1...9).map { "com.game.app\($0)" }
        let adb = ConcurrentLabelADB(packages: packages)
        let catalog = AppCatalog(adb: adb)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        _ = try await catalog.listApps(on: device)

        XCTAssertLessThanOrEqual(adb.maximumConcurrentLabelLookups, 4)
    }

    func testApplicationLabelResultsAreCachedForTheCurrentRun() async throws {
        let packages = (1...3).map { "com.game.app\($0)" }
        let adb = ConcurrentLabelADB(packages: packages)
        let catalog = AppCatalog(adb: adb)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb
        )

        _ = try await catalog.listApps(on: device)
        _ = try await catalog.listApps(on: device)

        XCTAssertEqual(adb.labelLookupCount, packages.count)
    }
}

private struct StubAppADB: ADBRuntimeProtocol {
    let packages: [String]
    let processOutput: String
    let applicationLabels: [String: String]

    init(
        packages: [String],
        processOutput: String,
        applicationLabels: [String: String] = [:]
    ) {
        self.packages = packages
        self.processOutput = processOutput
        self.applicationLabels = applicationLabels
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        switch command {
        case .listThirdPartyPackages:
            return .success(stdout: packages.map { "package:\($0)" }.joined(separator: "\n"))
        case .resolvePIDs:
            return .success(stdout: processOutput)
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

private final class ConcurrentLabelADB: ADBRuntimeProtocol, @unchecked Sendable {
    private let packages: [String]
    private let lock = NSLock()
    private var activeLabelLookups = 0
    private var recordedMaximumConcurrentLabelLookups = 0
    private var recordedLabelLookupCount = 0

    var maximumConcurrentLabelLookups: Int {
        lock.withLock { recordedMaximumConcurrentLabelLookups }
    }

    var labelLookupCount: Int {
        lock.withLock { recordedLabelLookupCount }
    }

    init(packages: [String]) {
        self.packages = packages
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        switch command {
        case .listThirdPartyPackages:
            return .success(stdout: packages.map { "package:\($0)" }.joined(separator: "\n"))
        case .applicationLabel(_, let packageName):
            lock.withLock {
                activeLabelLookups += 1
                recordedLabelLookupCount += 1
                recordedMaximumConcurrentLabelLookups = max(recordedMaximumConcurrentLabelLookups, activeLabelLookups)
            }
            try await Task.sleep(for: .milliseconds(20))
            lock.withLock { activeLabelLookups -= 1 }
            return .success(stdout: "application-label:'\(packageName.value)'")
        default:
            return .success()
        }
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
