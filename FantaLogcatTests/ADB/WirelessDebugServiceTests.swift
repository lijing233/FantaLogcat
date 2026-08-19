import XCTest
@testable import FantaLogcat

final class WirelessDebugServiceTests: XCTestCase {
    func testPairingKeyPayloadUsesAndroidQRFormat() {
        let key = WirelessPairingKey(serviceName: "fantalogcat-abc12345", psk: "(Aq+v9>Cx>!/")

        XCTAssertEqual(key.qrPayload, "WIFI:T:ADB;S:fantalogcat-abc12345;P:(Aq+v9>Cx>!/;;")
    }

    func testMakeGeneratesValidServiceNameAndPSK() {
        let key = WirelessPairingKey.make()

        XCTAssertTrue(key.serviceName.hasPrefix("studio-"))
        XCTAssertEqual(key.serviceName.count, "studio-".count + 10)
        XCTAssertEqual(key.psk.count, 11)
        // PSK 与实例名不含 QR 分隔符，避免破坏载荷结构
        for field in [key.serviceName, key.psk] {
            XCTAssertFalse(field.contains(";"))
            XCTAssertFalse(field.contains(":"))
            XCTAssertFalse(field.contains(","))
        }
    }

    func testParseAddressIPv4() throws {
        let endpoint = try XCTUnwrap(WirelessDebugService.parseAddress("192.168.1.5:37755"))

        XCTAssertEqual(endpoint, try ADBEndpoint(host: "192.168.1.5", port: 37_755))
    }

    func testParseAddressIPv6() throws {
        let endpoint = try XCTUnwrap(WirelessDebugService.parseAddress("[fe80::1]:37755"))

        XCTAssertEqual(endpoint, try ADBEndpoint(host: "fe80::1", port: 37_755))
        XCTAssertEqual(endpoint.argument, "[fe80::1]:37755")
    }

    func testParseAddressRejectsMalformed() {
        XCTAssertNil(WirelessDebugService.parseAddress("not-an-address"))
        XCTAssertNil(WirelessDebugService.parseAddress("host:"))
        XCTAssertNil(WirelessDebugService.parseAddress(":5555"))
    }

    func testParseWiFiIPPrefersWLANOverTethering() {
        let output = """
        1: lo    inet 127.0.0.1/8 scope host lo\\
        2: rndis0    inet 192.168.42.129/24 scope global rndis0\\
        3: wlan0    inet 192.168.1.5/24 brd 192.168.1.255 scope global wlan0\\
        """

        XCTAssertEqual(WirelessDebugService.parseWiFiIP(from: output), "192.168.1.5")
    }

    func testParseWiFiIPReturnsNilWithoutGlobalAddress() {
        let output = "1: lo    inet 127.0.0.1/8 scope host lo\\"

        XCTAssertNil(WirelessDebugService.parseWiFiIP(from: output))
    }

    func testParseWiFiIPFallsBackWhenNoWLAN() {
        let output = "2: eth0    inet 10.0.0.8/24 brd 10.0.0.255 scope global eth0\\"

        XCTAssertEqual(WirelessDebugService.parseWiFiIP(from: output), "10.0.0.8")
    }

    func testParsePairingEndpointPrefersMatchingServiceName() throws {
        let output = """
        List of discovered mdns services
        adb-OTHER	_adb-tls-pairing._tcp	192.168.1.9:40001
        fantalogcat-abc12345	_adb-tls-pairing._tcp	192.168.1.5:37755
        """

        let endpoint = WirelessDebugService.parsePairingEndpoint(
            from: output,
            serviceName: "fantalogcat-abc12345"
        )

        XCTAssertEqual(endpoint, try ADBEndpoint(host: "192.168.1.5", port: 37_755))
    }

    func testParsePairingEndpointReturnsNilWhenServiceNameDoesNotMatch() throws {
        let output = """
        List of discovered mdns services
        adb-OTHER	_adb-tls-pairing._tcp	192.168.1.9:40001
        """

        let endpoint = WirelessDebugService.parsePairingEndpoint(
            from: output,
            serviceName: "fantalogcat-abc12345"
        )

        XCTAssertNil(endpoint)
    }

    func testParsePairingEndpointReturnsNilWithoutPairingService() {
        let output = """
        List of discovered mdns services
        _http._tcp	printer	192.168.1.2:80
        """

        XCTAssertNil(WirelessDebugService.parsePairingEndpoint(
            from: output,
            serviceName: "fantalogcat-abc12345"
        ))
    }

    func testPairRecordsPairCommandWithRawSecret() async throws {
        let runtime = RecordingADBRuntime()
        let service = WirelessDebugService(adb: runtime)
        let endpoint = try ADBEndpoint(host: "192.168.1.5", port: 37_755)

        try await service.pair(endpoint: endpoint, secret: "(Aq+v9>Cx>!/")

        XCTAssertEqual(runtime.runCommands, [.pair(endpoint, secret: "(Aq+v9>Cx>!/")])
    }

    func testEnableTCPIPRejectsOutOfRangePort() async throws {
        let runtime = RecordingADBRuntime()
        let service = WirelessDebugService(adb: runtime)
        let serial = try ADBDeviceSerial("ABC123")

        do {
            try await service.enableTCPIP(serial: serial, port: 70_000)
            XCTFail("Expected invalid endpoint")
        } catch let error as ADBValidationError {
            XCTAssertEqual(error, .invalidEndpoint)
        }
    }

    func testMDNSAvailableReturnsFalseWhenCheckFails() async {
        let service = WirelessDebugService(adb: ThrowingADBRuntime())

        let available = await service.mDNSAvailable()

        XCTAssertFalse(available)
    }

    func testMDNSAvailableReturnsTrueWhenCheckSucceeds() async {
        let service = WirelessDebugService(adb: RecordingADBRuntime())

        let available = await service.mDNSAvailable()

        XCTAssertTrue(available)
    }

    func testDisconnectRecordsDisconnectAddress() async throws {
        let runtime = RecordingADBRuntime()
        let service = WirelessDebugService(adb: runtime)

        try await service.disconnect(address: "192.168.1.5:5555")

        XCTAssertEqual(runtime.runCommands, [.disconnect(address: "192.168.1.5:5555")])
    }

    func testDisconnectAcceptsMDNSInstanceNameSerial() async throws {
        let runtime = RecordingADBRuntime()
        let service = WirelessDebugService(adb: runtime)

        try await service.disconnect(address: "adb-14141FDF600081-TnSdi9")

        XCTAssertEqual(runtime.runCommands, [.disconnect(address: "adb-14141FDF600081-TnSdi9")])
    }

    func testRestoreUSBRecordsUSBCommand() async throws {
        let runtime = RecordingADBRuntime()
        let service = WirelessDebugService(adb: runtime)
        let serial = try ADBDeviceSerial("ABC123")

        try await service.restoreUSB(serial: serial)

        XCTAssertEqual(runtime.runCommands, [.usb(serial)])
    }
}

private final class RecordingADBRuntime: ADBRuntimeProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [ADBCommand] = []

    var runCommands: [ADBCommand] { lock.withLock { commands } }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        lock.withLock { commands.append(command) }
        return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class ThrowingADBRuntime: ADBRuntimeProtocol, @unchecked Sendable {
    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        throw ADBError.commandFailed(exitCode: 1, stderrSummary: "")
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
