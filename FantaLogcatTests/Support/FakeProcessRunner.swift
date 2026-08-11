import Foundation
@testable import FantaLogcat

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: URL
        let arguments: [String]
        let timeout: Duration
    }

    private let lock = NSLock()
    private let result: Result<ProcessResult, Error>
    private var invocation: Invocation?

    init(result: Result<ProcessResult, Error>) {
        self.result = result
    }

    var lastInvocation: Invocation? {
        lock.withLock { invocation }
    }

    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        lock.withLock {
            invocation = Invocation(executable: executable, arguments: arguments, timeout: timeout)
        }
        return try result.get()
    }

    func stream(
        executable: URL,
        arguments: [String]
    ) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

extension ProcessResult {
    static func success(stdout: String = "", stderr: String = "") -> ProcessResult {
        ProcessResult(
            exitCode: 0,
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
