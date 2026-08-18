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
            ADBCommand.logcatThreadtime(serial).arguments,
            ["-s", "ABC123", "logcat", "-v", "threadtime"]
        )
        XCTAssertEqual(
            ADBCommand.logcatSnapshotThreadtime(serial, lineLimit: 4_000).arguments,
            ["-s", "ABC123", "logcat", "-d", "-t", "4000", "-v", "threadtime"]
        )
        XCTAssertEqual(
            ADBCommand.logcatSnapshotThreadtime(serial, lineLimit: nil).arguments,
            ["-s", "ABC123", "logcat", "-d", "-v", "threadtime"]
        )
        XCTAssertEqual(
            ADBCommand.pidOf(serial, package).arguments,
            ["-s", "ABC123", "shell", "pidof", "com.example.game"]
        )
        XCTAssertEqual(
            ADBCommand.stopApplication(serial, package).arguments,
            ["-s", "ABC123", "shell", "am", "force-stop", "com.example.game"]
        )
        XCTAssertEqual(
            ADBCommand.clearApplicationData(serial, package).arguments,
            ["-s", "ABC123", "shell", "pm", "clear", "com.example.game"]
        )
        XCTAssertEqual(
            ADBCommand.screenshot(serial).arguments,
            ["-s", "ABC123", "exec-out", "screencap", "-p"]
        )
        XCTAssertEqual(
            ADBCommand.listThirdPartyPackagePaths(serial).arguments,
            ["-s", "ABC123", "shell", "pm", "list", "packages", "-3", "-f"]
        )
        XCTAssertEqual(
            ADBCommand.applicationDetails(serial, package).arguments,
            ["-s", "ABC123", "shell", "dumpsys", "package", "com.example.game"]
        )
        XCTAssertEqual(
            ADBCommand.advertisingID(serial).arguments,
            ["-s", "ABC123", "shell", "settings", "get", "secure", "advertising_id"]
        )
    }

    func testBuildsSafeToolArguments() throws {
        let serial = try ADBDeviceSerial("ABC123")
        let package = try AndroidPackageName("com.example.game")
        let apk = URL(fileURLWithPath: "/tmp/My Game.apk")
        let options = APKInstallOptions(
            replaceExisting: true,
            allowTestPackages: true,
            grantRuntimePermissions: true,
            allowDowngrade: false
        )

        XCTAssertEqual(
            ADBCommand.installAPK(serial, apk, options).arguments,
            ["-s", "ABC123", "install", "-r", "-t", "-g", "/tmp/My Game.apk"]
        )
        XCTAssertEqual(
            ADBCommand.openDeepLink(
                serial,
                try ADBDeepLink("mygame://level?id=7&mode=test"),
                package
            ).arguments,
            [
                "-s", "ABC123", "shell", "am", "start", "-W", "-a",
                "android.intent.action.VIEW", "-d",
                "'mygame://level?id=7&mode=test'", "-p", "com.example.game"
            ]
        )
        let component = try AndroidActivityComponent(
            "adb shell am start -n com.example.game/com.example.game.DebugActivity"
        )
        XCTAssertEqual(component.value, "com.example.game/com.example.game.DebugActivity")
        XCTAssertEqual(
            ADBCommand.currentActivity(serial).arguments,
            ["-s", "ABC123", "shell", "dumpsys", "activity", "activities"]
        )
        XCTAssertEqual(
            ADBCommand.openActivity(serial, component).arguments,
            [
                "-s", "ABC123", "shell", "am", "start", "-W", "-n",
                "com.example.game/com.example.game.DebugActivity"
            ]
        )
        XCTAssertEqual(
            ADBCommand.openActivityAsPackage(serial, component).arguments,
            [
                "-s", "ABC123", "shell", "run-as", "com.example.game",
                "am", "start", "-W", "-n", "com.example.game/com.example.game.DebugActivity"
            ]
        )
        XCTAssertEqual(
            ADBCommand.inputText(serial, try ADBInputText("hello world+1")).arguments,
            ["-s", "ABC123", "shell", "input", "text", "hello%sworld+1"]
        )
        let json = try ADBJSONText(#"{"name":"Fanta","count":2}"#)
        XCTAssertEqual(json.value, #"{"count":2,"name":"Fanta"}"#)
        XCTAssertEqual(
            ADBCommand.inputJSON(serial, json).arguments,
            [
                "-s", "ABC123", "shell",
                "payload=eyJjb3VudCI6MiwibmFtZSI6IkZhbnRhIn0=; decoded=$(printf %s \"$payload\" | base64 -d) || exit 1; input text \"$decoded\""
            ]
        )
        XCTAssertThrowsError(try ADBDeepLink("no-scheme"))
        XCTAssertThrowsError(try AndroidActivityComponent("com.example.game"))
        XCTAssertEqual(
            try AndroidActivityComponent("com.example.game/.DebugActivity").value,
            "com.example.game/.DebugActivity"
        )
        XCTAssertThrowsError(try ADBInputText("中文"))
        XCTAssertThrowsError(try ADBInputText("unsafe;command"))
        XCTAssertThrowsError(try ADBJSONText("not json"))
        XCTAssertEqual(
            try ADBJSONText(#"{"name":"中文😺"}"#).value,
            #"{"name":"\u4E2D\u6587\uD83D\uDE3A"}"#
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
