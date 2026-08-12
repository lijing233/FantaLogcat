import Foundation
import XCTest
@testable import FantaLogcat

final class ADBRuntimeTests: XCTestCase {
    func testDevicesUsesArgumentArrayAndRejectsControlCharacters() async throws {
        let runner = FakeProcessRunner(result: .success(.success(stdout: "List of devices attached\n")))
        let runtime = ADBRuntime(
            executableURL: URL(fileURLWithPath: "/managed/adb"),
            runner: runner
        )

        _ = try await runtime.run(.devices(longFormat: true), timeout: .seconds(5))

        XCTAssertEqual(runner.lastInvocation?.arguments, ["devices", "-l"])
        XCTAssertThrowsError(try ADBEndpoint(host: "127.0.0.1;open /tmp/x", port: 5555))
    }

    func testPairingCodeNeverAppearsInCommandFailure() async throws {
        let runner = FakeProcessRunner(result: .success(ProcessResult(
            exitCode: 1,
            stdout: Data(),
            stderr: Data(("pairing failed for code 123456 " + String(repeating: "failure ", count: 600)).utf8)
        )))
        let runtime = ADBRuntime(
            executableURL: URL(fileURLWithPath: "/managed/adb"),
            runner: runner,
            maximumErrorBytes: 128
        )
        let endpoint = try ADBEndpoint(host: "127.0.0.1", port: 5555)
        let code = try ADBPairingCode("123456")

        do {
            _ = try await runtime.run(.pair(endpoint, code), timeout: .seconds(5))
            XCTFail("Expected command failure")
        } catch let error as ADBError {
            guard case .commandFailed(_, let summary) = error else {
                return XCTFail("Unexpected ADB error: \(error)")
            }
            XCTAssertLessThanOrEqual(summary.utf8.count, 128)
            XCTAssertFalse(summary.contains("123456"))
        }
    }

    func testBuildsClosedArgumentsForDeviceCommands() throws {
        let serial = try ADBDeviceSerial("ABC123")
        let package = try AndroidPackageName("com.example.game")

        XCTAssertEqual(
            ADBCommand.resolvePIDs(serial, package).arguments,
            ["-s", "ABC123", "shell", "ps", "-A", "-o", "PID,NAME"]
        )
        XCTAssertEqual(
            ADBCommand.applicationLabel(serial, package).arguments,
            [
                "-s", "ABC123", "shell",
                "dumpsys package com.example.game | grep -m 1 '^[[:space:]]*application-label:'"
            ]
        )
        XCTAssertEqual(
            ADBCommand.logcatThreadtime(serial, pids: [42, 43]).arguments,
            ["-s", "ABC123", "logcat", "-v", "threadtime", "--pid=42", "--pid=43"]
        )
        XCTAssertEqual(
            ADBCommand.logcatSnapshotThreadtime(serial, pids: [42], lineCount: 900).arguments,
            ["-s", "ABC123", "logcat", "-d", "-t", "500", "-v", "threadtime", "--pid=42"]
        )
    }

    func testRejectsInvalidValidatedValues() {
        XCTAssertThrowsError(try ADBDeviceSerial("device\nother"))
        XCTAssertThrowsError(try AndroidPackageName("com.example;rm"))
        XCTAssertThrowsError(try ADBPairingCode("12 456"))
        XCTAssertThrowsError(try ADBEndpoint(host: "", port: 5555))
        XCTAssertThrowsError(try ADBEndpoint(host: "localhost", port: 0))
    }
}
