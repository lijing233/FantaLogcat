import Foundation
import XCTest
@testable import FantaLogcat

final class ProcessRunnerTests: XCTestCase {
    func testRunDrainsStdoutAndStderrConcurrently() async throws {
        let runner = FoundationProcessRunner()
        let script = "i=0; while [ $i -lt 2000 ]; do printf o; printf e >&2; i=$((i+1)); done"

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: .seconds(5)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 2_000)
        XCTAssertEqual(result.stderr.count, 2_000)
    }

    func testRunTerminatesProcessAtTimeout() async {
        let runner = FoundationProcessRunner()

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
        }
    }

    func testRunTerminatesProcessWhenTaskIsCancelled() async {
        let runner = FoundationProcessRunner()
        let task = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(50))

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testStreamReportsBothPipesAndExit() async throws {
        let runner = FoundationProcessRunner()
        let stream = try runner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf out; printf err >&2"]
        )
        var stdout = Data()
        var stderr = Data()
        var exitCode: Int32?

        for try await output in stream {
            switch output {
            case .stdout(let data): stdout.append(data)
            case .stderr(let data): stderr.append(data)
            case .exited(let code): exitCode = code
            }
        }

        XCTAssertEqual(String(decoding: stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: stderr, as: UTF8.self), "err")
        XCTAssertEqual(exitCode, 0)
    }

    func testStreamDeliversAShortRunningProcessOutputWithoutWaitingForItsExit() async throws {
        let runner = FoundationProcessRunner()
        let clock = ContinuousClock()
        let started = clock.now
        let stream = try runner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf ready; sleep 2"]
        )
        var iterator = stream.makeAsyncIterator()

        let first = try await iterator.next()

        guard case .stdout(let output)? = first else {
            return XCTFail("Expected immediate stdout output")
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "ready")
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testTimeoutReturnsEvenWhenProcessIgnoresTerminate() async {
        let runner = FoundationProcessRunner()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                timeout: .milliseconds(50)
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
        }

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testLeavingStreamEarlyTerminatesProcessPromptly() async throws {
        let runner = FoundationProcessRunner()
        let stream = try runner.stream(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"]
        )
        let task = Task {
            for try await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let started = clock.now

        task.cancel()
        _ = try? await task.value

        XCTAssertLessThan(started.duration(to: clock.now), .seconds(1))
    }

    func testStreamFailsExplicitlyWhenBoundedBufferOverflows() async throws {
        let runner = FoundationProcessRunner()
        let stream = try runner.stream(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: []
        )
        try await Task.sleep(for: .milliseconds(200))

        do {
            for try await _ in stream {}
            XCTFail("Expected bounded buffer overflow")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .outputBufferOverflow)
        }
    }
}
