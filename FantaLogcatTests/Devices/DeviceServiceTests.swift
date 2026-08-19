import Foundation
import XCTest
@testable import FantaLogcat

final class DeviceServiceTests: XCTestCase {
    func testUnauthorizedDeviceProducesActionableState() async throws {
        let adb = StubDeviceADB(output: """
        List of devices attached
        ABC123 unauthorized usb:1-1 product:husky model:Pixel_8 device:husky
        """)
        let state = try await DeviceService(adb: adb).refresh()

        XCTAssertEqual(
            state,
            .authorizationRequired(.init(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb))
        )
    }

    func testMultipleOnlineDevicesRequireExplicitSelection() async throws {
        let adb = StubDeviceADB(output: """
        List of devices attached
        emulator-5554 device product:sdk_gphone model:Pixel_9 device:emu transport_id:1
        R5CT20A1234 device usb:1-1 product:husky model:Pixel_8 device:husky transport_id:2
        """)
        let state = try await DeviceService(adb: adb).refresh()

        guard case .selectionRequired(let devices) = state else {
            return XCTFail("Expected selectionRequired, got \(state)")
        }
        XCTAssertEqual(devices.map(\.displayName), ["Pixel 8", "Pixel 9"])
    }

    func testSingleOnlineDeviceConnectsWithoutExposingSerialAsName() async throws {
        let adb = StubDeviceADB(output: """
        List of devices attached
        R5CT20A1234 device usb:1-1 product:husky model:Pixel_8 device:husky
        """)
        let state = try await DeviceService(adb: adb).refresh()

        XCTAssertEqual(
            state,
            .connected(.init(serial: try ADBDeviceSerial("R5CT20A1234"), displayName: "Pixel 8", transport: .usb))
        )
    }

    func testTLSWirelessDeviceIsIdentifiedByMDNSInstanceName() async throws {
        let adb = StubDeviceADB(output: """
        List of devices attached
        adb-14141FDF600081-TnSdi9 device product:husky model:Pixel_8 device:husky transport_id:1
        """)
        let state = try await DeviceService(adb: adb).refresh()

        XCTAssertEqual(
            state,
            .connected(.init(serial: try ADBDeviceSerial("adb-14141FDF600081-TnSdi9"), displayName: "Pixel 8", transport: .wirelessTLS))
        )
    }

    func testTCPIPWirelessDeviceIsIdentifiedByIPPortSerial() async throws {
        let adb = StubDeviceADB(output: """
        List of devices attached
        192.168.1.5:5555 device product:husky model:Pixel_8 device:husky transport_id:1
        """)
        let state = try await DeviceService(adb: adb).refresh()

        XCTAssertEqual(
            state,
            .connected(.init(serial: try ADBDeviceSerial("192.168.1.5:5555"), displayName: "Pixel 8", transport: .wirelessTCPIP))
        )
    }
}

private struct StubDeviceADB: ADBRuntimeProtocol {
    let output: String

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        XCTAssertEqual(command, .devices(longFormat: true))
        return .success(stdout: output)
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
