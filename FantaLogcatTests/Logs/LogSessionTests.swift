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
        XCTAssertEqual(runtime.lastCommand, .logcatThreadtime(device.serial))
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
        XCTAssertEqual(runtime.lastRunCommand, .logcatSnapshotThreadtime(device.serial))
    }


    func testEventsFlushesAnIdleFinalLineWithoutWaitingForTheNextADBChunk() async throws {
        let runtime = IdleStreamingADBRuntime()
        let session = LogSession(adb: runtime)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("SERIAL"),
            displayName: "Pixel",
            transport: .usb
        )
        let stream = try session.events(on: device, pids: [])
        let nextEvent = Task {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        await waitUntil { runtime.hasSubscriber }
        runtime.emit(.stdout(Data("08-12 10:00:01.123  1234  1234 D Android.revenueToMMP: sent\n".utf8)))

        let event = try await nextEvent.value
        XCTAssertEqual(event?.androidTag, "Android.revenueToMMP")
        XCTAssertEqual(event?.message, "sent")
    }

    func testEventsFiltersByMultiplePIDsOnTheHost() async throws {
        let runtime = StreamingADBRuntime(outputs: [
            .stdout(Data(
                ("08-12 10:00:01.123  1234  1234 D Unity: main\n"
                 + "08-12 10:00:01.124  5678  5678 D Unity: child\n"
                 + "08-12 10:00:01.125  9999  9999 D Unity: other\n").utf8
            ))
        ])
        let session = LogSession(adb: runtime)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("SERIAL"),
            displayName: "Pixel",
            transport: .usb
        )

        let events = try await session.events(on: device, pids: [1234, 5678]).collect()

        XCTAssertEqual(events.map(\.message), ["main", "child"])
    }

    func testEventsFinishesWithErrorWhenADBExitsNonZero() async throws {
        let runtime = StreamingADBRuntime(outputs: [
            .stdout(Data("08-12 10:00:01.123  1234  1234 D Unity: ready\n".utf8)),
            .stderr(Data("logcat: failure\n".utf8)),
            .exited(1)
        ])
        let session = LogSession(adb: runtime)
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("SERIAL"),
            displayName: "Pixel",
            transport: .usb
        )

        var received: [LogEvent] = []
        do {
            for try await event in try session.events(on: device, pids: [1234]) {
                received.append(event)
            }
            XCTFail("Expected the stream to throw a non-zero exit error")
        } catch let error as LogSessionError {
            guard case .processExitedNonZero(let exitCode, _) = error else {
                return XCTFail("Unexpected LogSessionError: \(error)")
            }
            XCTAssertEqual(exitCode, 1)
        }

        XCTAssertEqual(received.map(\.message), ["ready"])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Condition was not satisfied before timeout")
                return
            }
            await Task.yield()
        }
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

private final class IdleStreamingADBRuntime: ADBRuntimeProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProcessOutput, Error>.Continuation?

    var hasSubscriber: Bool {
        lock.withLock { continuation != nil }
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        .success()
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func emit(_ output: ProcessOutput) {
        _ = lock.withLock { continuation?.yield(output) }
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
