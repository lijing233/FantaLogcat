import Foundation
import XCTest
@testable import FantaLogcat

final class ADBToolServiceTests: XCTestCase {
    func testInstallAPKUsesSelectedDeviceAndClosedArguments() async throws {
        let adb = RecordingToolADB()
        let service = ADBToolService(adb: adb)
        let device = try makeDevice()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apk = directory.appendingPathComponent("Game Build.apk")
        try Data("apk".utf8).write(to: apk)

        let result = try await service.installAPK(
            at: apk,
            on: device,
            options: APKInstallOptions(allowTestPackages: true)
        )

        let commands = await adb.commands
        XCTAssertEqual(result.packageName, try AndroidPackageName("com.example.game"))
        XCTAssertEqual(result.appInfo?.versionName, "1.2.3")
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(
            commands[1].arguments,
            ["-s", "DEVICE-1", "install", "-r", "-t", apk.path]
        )
    }

    func testRestartAndClearDataUseTheExplicitPackage() async throws {
        let adb = RecordingToolADB()
        let service = ADBToolService(adb: adb)
        let device = try makeDevice()
        let package = try AndroidPackageName("com.example.game")

        try await service.restart(package, on: device)
        try await service.closeApplication(package, on: device)
        try await service.clearData(for: package, on: device)

        let commands = await adb.commands
        XCTAssertEqual(commands, [
            .stopApplication(device.serial, package),
            .startApplication(device.serial, package),
            .stopApplication(device.serial, package),
            .clearApplicationData(device.serial, package)
        ])
    }

    func testReadsAndOpensForegroundActivity() async throws {
        let adb = RecordingToolADB()
        let service = ADBToolService(adb: adb)
        let device = try makeDevice()

        let component = try await service.currentActivity(on: device)
        let output = try await service.openActivity(component, on: device)

        XCTAssertEqual(component.value, "com.example.game/com.example.game.DebugActivity")
        XCTAssertEqual(output, "Starting: Intent")
        let commands = await adb.commands
        XCTAssertEqual(commands, [
            .currentActivity(device.serial),
            .openActivity(device.serial, component)
        ])
    }

    func testNonExportedActivityFallsBackToRunAsPackage() async throws {
        let adb = RecordingToolADB(overrides: [.activityPermissionDenied: Data()])
        let service = ADBToolService(adb: adb)
        let device = try makeDevice()
        let component = try AndroidActivityComponent("com.example.game/.PrivateActivity")

        let output = try await service.openActivity(component, on: device)

        XCTAssertEqual(output, "Starting as package")
        let commands = await adb.commands
        XCTAssertEqual(commands, [
            .openActivity(device.serial, component),
            .openActivityAsPackage(device.serial, component)
        ])
    }

    func testJSONIsValidatedNormalizedAndSentThroughEncodedPayload() async throws {
        let adb = RecordingToolADB()
        let service = ADBToolService(adb: adb)
        let device = try makeDevice()

        let normalized = try await service.normalizedJSON(#"{"name":"Fanta","count":2}"#)
        XCTAssertEqual(normalized, #"{"count":2,"name":"Fanta"}"#)
        try await service.sendJSON(#"{"name":"Fanta","count":2}"#, pressEnter: true, on: device)

        let commands = await adb.commands
        XCTAssertEqual(commands.count, 2)
        guard case .inputJSON(_, let payload) = commands[0] else {
            return XCTFail("Expected JSON input command")
        }
        XCTAssertEqual(payload.value, normalized)
        XCTAssertEqual(commands[1], .inputKeyEvent(device.serial, 66))
    }

    func testScreenshotRejectsNonPNGOutput() async throws {
        let adb = RecordingToolADB(overrides: [.screenshot: Data("not png".utf8)])
        let service = ADBToolService(adb: adb)

        do {
            _ = try await service.screenshot(on: try makeDevice())
            XCTFail("Expected invalid screenshot")
        } catch let error as ADBValidationError {
            XCTAssertEqual(error, .invalidScreenshot)
        }
    }

    func testDeviceInfoCombinesTypedPropertyCommands() async throws {
        let adb = RecordingToolADB()
        let service = ADBToolService(adb: adb)

        let info = try await service.deviceInfo(on: try makeDevice())

        XCTAssertEqual(info.manufacturer, "Fanta")
        XCTAssertEqual(info.model, "Test Phone")
        XCTAssertEqual(info.androidVersion, "16")
        XCTAssertEqual(info.sdk, "36")
        XCTAssertEqual(info.abi, "arm64-v8a")
        XCTAssertEqual(info.screenSize, "1080x2400")
        XCTAssertEqual(info.screenDensity, "420")
        XCTAssertEqual(info.battery, "85%, 31.5°C, charging")
        XCTAssertEqual(info.dataStorage, "20G / 100G (20%)")
        XCTAssertEqual(info.advertisingID, "12345678-1234-1234-1234-123456789abc")
    }

    private func makeDevice() throws -> DeviceDescriptor {
        DeviceDescriptor(
            serial: try ADBDeviceSerial("DEVICE-1"),
            displayName: "Test Phone",
            transport: .usb
        )
    }
}

private actor RecordingToolADB: ADBRuntimeProtocol {
    enum OverrideKey: Hashable {
        case screenshot
        case activityPermissionDenied
    }

    private(set) var commands: [ADBCommand] = []
    private var packagePathReadCount = 0
    private let overrides: [OverrideKey: Data]

    init(overrides: [OverrideKey: Data] = [:]) {
        self.overrides = overrides
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        commands.append(command)
        if case .openActivity = command, overrides[.activityPermissionDenied] != nil {
            throw ADBError.commandFailed(
                exitCode: 255,
                stderrSummary: "Security exception: Permission Denial: not exported"
            )
        }
        let output: Data
        switch command {
        case .screenshot:
            output = overrides[.screenshot] ?? Data([0x89, 0x50, 0x4E, 0x47])
        case .deviceProperty(_, let property):
            let value = switch property {
            case .manufacturer: "Fanta"
            case .model: "Test Phone"
            case .androidVersion: "16"
            case .sdk: "36"
            case .abi: "arm64-v8a"
            }
            output = Data(value.utf8)
        case .screenSize:
            output = Data("Physical size: 1080x2400\n".utf8)
        case .screenDensity:
            output = Data("Physical density: 420\n".utf8)
        case .batteryDetails:
            output = Data("status: 2\nlevel: 85\ntemperature: 315\n".utf8)
        case .dataStorage:
            output = Data("Filesystem Size Used Avail Use% Mounted on\n/data 100G 20G 80G 20% /data\n".utf8)
        case .advertisingID:
            output = Data("12345678-1234-1234-1234-123456789abc\n".utf8)
        case .listThirdPartyPackagePaths:
            packagePathReadCount += 1
            output = packagePathReadCount == 1
                ? Data()
                : Data("package:/data/app/base.apk=com.example.game\n".utf8)
        case .applicationDetails:
            output = Data("""
                versionCode=42 minSdk=24 targetSdk=35
                versionName=1.2.3
                firstInstallTime=2026-08-17 10:00:00
                lastUpdateTime=2026-08-17 16:00:00
                """.utf8)
        case .currentActivity:
            output = Data("mResumedActivity: ActivityRecord{123 u0 com.example.game/com.example.game.DebugActivity t42}\n".utf8)
        case .openActivity:
            output = Data("Starting: Intent\n".utf8)
        case .openActivityAsPackage:
            output = Data("Starting as package\n".utf8)
        default:
            output = Data()
        }
        return ProcessResult(exitCode: 0, stdout: output, stderr: Data())
    }

    nonisolated func stream(
        _ command: ADBCommand
    ) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
