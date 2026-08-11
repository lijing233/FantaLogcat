import Foundation

protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult
    func stream(executable: URL, arguments: [String]) throws -> AsyncThrowingStream<ProcessOutput, Error>
}

enum ProcessOutput: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
}

struct ProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunnerError: Error, Equatable {
    case timedOut
}

final class FoundationProcessRunner: ProcessRunning, @unchecked Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = ProcessBox(process)
        let waiter = ProcessWaiter(processBox: processBox)
        waiter.prepare()
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw error
        }

        let stdoutTask = Task.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            let exitCode = try await waiter.wait(timeout: timeout)
            return await ProcessResult(
                exitCode: exitCode,
                stdout: stdoutTask.value,
                stderr: stderrTask.value
            )
        } catch {
            processBox.terminate()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }
    }

    func stream(
        executable: URL,
        arguments: [String]
    ) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let processBox = ProcessBox(process)
        let pair = AsyncThrowingStream<ProcessOutput, Error>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { pair.continuation.yield(.stdout(data)) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { pair.continuation.yield(.stderr(data)) }
        }
        process.terminationHandler = { process in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if !stdoutTail.isEmpty { pair.continuation.yield(.stdout(stdoutTail)) }
            if !stderrTail.isEmpty { pair.continuation.yield(.stderr(stderrTail)) }
            pair.continuation.yield(.exited(process.terminationStatus))
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { @Sendable _ in
            processBox.terminate()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            pair.continuation.finish(throwing: error)
            throw error
        }
        return pair.stream
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        lock.withLock {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let processBox: ProcessBox
    private var result: Result<Int32, Error>?
    private var continuation: CheckedContinuation<Int32, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(processBox: ProcessBox) {
        self.processBox = processBox
    }

    func prepare() {
        processBox.process.terminationHandler = { [weak self] process in
            self?.resolve(.success(process.terminationStatus))
        }
    }

    func wait(timeout: Duration) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Int32, Error>? = lock.withLock {
                    if let result { return result }
                    self.continuation = continuation
                    timeoutTask = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        self?.processBox.terminate()
                        self?.resolve(.failure(ProcessRunnerError.timedOut))
                    }
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            processBox.terminate()
            resolve(.failure(CancellationError()))
        }
    }

    private func resolve(_ newResult: Result<Int32, Error>) {
        let continuation: CheckedContinuation<Int32, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = newResult
            timeoutTask?.cancel()
            timeoutTask = nil
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: newResult)
    }
}
