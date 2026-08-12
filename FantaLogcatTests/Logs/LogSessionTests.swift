import Foundation
import XCTest
@testable import FantaLogcat

final class LogSessionTests: XCTestCase {
    func testEventsParsesThreadtimeOutputFromADBStream() async throws {
        let runtime = StreamingADBRuntime(outputs: [
            .stdout(Data("08-12 10:00:01.123  1234  1234 I Unity   : engine ready\n".utf8))
        ])
        let session = LogSession(adb: runtime)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("SERIAL"),
            displayName: "Pixel",
            transport: .usb
        )

        let events = try await session.events(on: device, pids: []).collect()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.androidTag, "Unity")
        XCTAssertEqual(events.first?.message, "engine ready")
        XCTAssertEqual(runtime.lastCommand, .logcatThreadtime(device.serial, pids: []))
    }

    func testRecentEventsParsesBoundedSnapshotBeforeLiveStream() async throws {
        let runtime = StreamingADBRuntime(
            outputs: [],
            snapshot: .success(stdout: "08-12 10:00:01.123  1234  1234 W Unity   : previous warning\n")
        )
        let session = LogSession(adb: runtime)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("SERIAL"),
            displayName: "Pixel",
            transport: .usb
        )

        let events = try await session.recentEvents(on: device, pids: [1234], limit: 500)

        XCTAssertEqual(events.map(\.message), ["previous warning"])
        XCTAssertEqual(events.map(\.priority), [.warning])
        XCTAssertEqual(runtime.lastRunCommand, .logcatSnapshotThreadtime(device.serial, pids: [1234], lineCount: 500))
    }
}

private final class StreamingADBRuntime: ADBRuntimeProtocol, @unchecked Sendable {
    let outputs: [ProcessOutput]
    let snapshot: ProcessResult
    private let lock = NSLock()
    private var command: ADBCommand?
    private var runCommand: ADBCommand?

    init(outputs: [ProcessOutput], snapshot: ProcessResult = .success()) {
        self.outputs = outputs
        self.snapshot = snapshot
    }

    var lastCommand: ADBCommand? {
        lock.withLock { command }
    }

    var lastRunCommand: ADBCommand? {
        lock.withLock { runCommand }
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        lock.withLock { self.runCommand = command }
        return snapshot
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        lock.withLock { self.command = command }
        return AsyncThrowingStream { continuation in
            outputs.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private extension AsyncThrowingStream where Element == LogEvent {
    func collect() async throws -> [LogEvent] {
        var result: [LogEvent] = []
        for try await event in self {
            result.append(event)
        }
        return result
    }
}
