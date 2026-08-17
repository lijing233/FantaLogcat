import Foundation
import XCTest
@testable import FantaLogcat

final class ScrcpyManagerTests: XCTestCase {
    func testManagedInstallExtractsOnlyRequiredOfficialFiles() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = temporary.appendingPathComponent(
            "source/scrcpy-macos-aarch64-v4.1",
            isDirectory: true
        )
        let archive = temporary.appendingPathComponent("fixture.tar.gz")
        let installRoot = temporary.appendingPathComponent("install", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for file in ["scrcpy", "scrcpy-server", "LICENSE", "scrcpy.png", "disconnected.png"] {
            try Data(file.utf8).write(to: sourceRoot.appendingPathComponent(file))
        }
        try makeArchive(sourceDirectory: sourceRoot.deletingLastPathComponent(), output: archive)

        let manager = ScrcpyManager(
            adbURL: URL(fileURLWithPath: "/managed/adb"),
            rootDirectory: installRoot,
            downloader: FixtureScrcpyDownloader(
                source: archive,
                reportedSHA256: ScrcpyManager.officialSHA256
            ),
            runner: FoundationProcessRunner(),
            systemSearchPaths: []
        )

        let initialAvailability = await manager.availability()
        XCTAssertEqual(initialAvailability, .installRequired)
        try await manager.install()
        let installedAvailability = await manager.availability()
        XCTAssertEqual(installedAvailability, .available(version: ScrcpyManager.version, managed: true))
    }

    func testManagedInstallRejectsChecksumMismatch() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("fixture.tar.gz")
        try Data("invalid".utf8).write(to: archive)
        let manager = ScrcpyManager(
            adbURL: URL(fileURLWithPath: "/managed/adb"),
            rootDirectory: temporary.appendingPathComponent("install"),
            downloader: FixtureScrcpyDownloader(source: archive, reportedSHA256: String(repeating: "0", count: 64)),
            runner: FoundationProcessRunner(),
            systemSearchPaths: []
        )

        do {
            try await manager.install()
            XCTFail("Expected checksum mismatch")
        } catch let error as ScrcpyManagerError {
            XCTAssertEqual(error, .checksumMismatch)
        }
    }

    func testLaunchAllowsOnlyOneProcessPerDeviceAndClearsStateAfterExit() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = temporary.appendingPathComponent("scrcpy")
        try Data("#!/bin/sh\n/bin/sleep 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let manager = ScrcpyManager(
            adbURL: URL(fileURLWithPath: "/managed/adb"),
            rootDirectory: temporary.appendingPathComponent("install"),
            downloader: FixtureScrcpyDownloader(source: executable, reportedSHA256: "unused"),
            runner: FoundationProcessRunner(),
            systemSearchPaths: [executable.path]
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("DEVICE-1"),
            displayName: "Test Phone",
            transport: .usb
        )

        try await manager.launch(on: device)
        let running = await manager.isRunning(on: device)
        XCTAssertTrue(running)
        do {
            try await manager.launch(on: device)
            XCTFail("Expected duplicate launch to be rejected")
        } catch let error as ScrcpyManagerError {
            XCTAssertEqual(error, .alreadyRunning)
        }

        await manager.stop(on: device)
        try await Task.sleep(for: .milliseconds(250))
        let stopped = await manager.isRunning(on: device)
        XCTAssertFalse(stopped)
    }

    private func makeArchive(sourceDirectory: URL, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = [
            "-czf", output.path,
            "-C", sourceDirectory.path,
            "scrcpy-macos-aarch64-v4.1"
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private struct FixtureScrcpyDownloader: DownloadClient {
    let source: URL
    let reportedSHA256: String

    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws -> DownloadReceipt {
        try FileManager.default.copyItem(at: source, to: destination)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return DownloadReceipt(byteCount: bytes, sha256: reportedSHA256)
    }
}
