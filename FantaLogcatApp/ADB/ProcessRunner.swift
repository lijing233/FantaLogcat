import Darwin
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
    case outputBufferOverflow
}

final class FoundationProcessRunner: ProcessRunning, @unchecked Sendable {
    private static let streamBufferChunks = 256

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
            processBox.stopSoon(
                closing: [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
            )
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
        let pair = AsyncThrowingStream<ProcessOutput, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.streamBufferChunks)
        )

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            pair.continuation.finish(throwing: error)
            throw error
        }

        let coordinator = Task.detached(priority: .utility) { [processBox] in
            let handles = [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
            let stdoutTask = Task.detached(priority: .utility) {
                try await Self.drain(
                    stdoutPipe.fileHandleForReading,
                    output: ProcessOutput.stdout,
                    continuation: pair.continuation,
                    processBox: processBox,
                    handles: handles
                )
            }
            let stderrTask = Task.detached(priority: .utility) {
                try await Self.drain(
                    stderrPipe.fileHandleForReading,
                    output: ProcessOutput.stderr,
                    continuation: pair.continuation,
                    processBox: processBox,
                    handles: handles
                )
            }

            do {
                try await stdoutTask.value
                try await stderrTask.value
                process.waitUntilExit()
                switch pair.continuation.yield(.exited(process.terminationStatus)) {
                case .enqueued:
                    pair.continuation.finish()
                case .dropped:
                    pair.continuation.finish(throwing: ProcessRunnerError.outputBufferOverflow)
                case .terminated:
                    break
                @unknown default:
                    pair.continuation.finish(throwing: ProcessRunnerError.outputBufferOverflow)
                }
            } catch {
                processBox.stopSoon(closing: handles)
                _ = try? await stdoutTask.value
                _ = try? await stderrTask.value
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            coordinator.cancel()
            processBox.stopSoon(
                closing: [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading]
            )
        }
        return pair.stream
    }

    private static func drain(
        _ handle: FileHandle,
        output: @escaping @Sendable (Data) -> ProcessOutput,
        continuation: AsyncThrowingStream<ProcessOutput, Error>.Continuation,
        processBox: ProcessBox,
        handles: [FileHandle]
    ) async throws {
        let completion = StreamDrainCompletion()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            completion.install(done)
            handle.readabilityHandler = { readableHandle in
                let data = readableHandle.availableData
                guard !data.isEmpty else {
                    readableHandle.readabilityHandler = nil
                    completion.finish(.success(()))
                    return
                }

                switch continuation.yield(output(data)) {
                case .enqueued:
                    break
                case .dropped:
                    readableHandle.readabilityHandler = nil
                    processBox.stopSoon(closing: handles)
                    completion.finish(.failure(ProcessRunnerError.outputBufferOverflow))
                case .terminated:
                    readableHandle.readabilityHandler = nil
                    completion.finish(.success(()))
                @unknown default:
                    readableHandle.readabilityHandler = nil
                    processBox.stopSoon(closing: handles)
                    completion.finish(.failure(ProcessRunnerError.outputBufferOverflow))
                }
            }
        }
    }
}

private final class StreamDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let immediate = lock.withLock { () -> Result<Void, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    let process: Process
    private var stopScheduled = false

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        lock.withLock {
            if process.isRunning { process.terminate() }
        }
    }

    func stopSoon(closing handles: [FileHandle]) {
        let shouldSchedule = lock.withLock {
            guard !stopScheduled else { return false }
            stopScheduled = true
            if process.isRunning { process.terminate() }
            return true
        }
        guard shouldSchedule else { return }

        Task.detached(priority: .high) { [self] in
            try? await Task.sleep(for: .milliseconds(100))
            lock.withLock {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
            handles.forEach { $0.closeFile() }
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
                        guard let self else { return }
                        if resolve(.failure(ProcessRunnerError.timedOut)) {
                            processBox.terminate()
                        }
                    }
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            if resolve(.failure(CancellationError())) {
                processBox.terminate()
            }
        }
    }

    @discardableResult
    private func resolve(_ newResult: Result<Int32, Error>) -> Bool {
        var didResolve = false
        let continuation: CheckedContinuation<Int32, Error>? = lock.withLock {
            guard result == nil else { return nil }
            didResolve = true
            result = newResult
            timeoutTask?.cancel()
            timeoutTask = nil
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: newResult)
        return didResolve
    }
}
