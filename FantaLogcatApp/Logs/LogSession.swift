import Foundation

protocol LogSessionProtocol: Sendable {
    func events(
        on device: DeviceDescriptor,
        pids: [Int32]
    ) throws -> AsyncThrowingStream<LogEvent, Error>
}

struct LogSession: LogSessionProtocol, Sendable {
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    func events(
        on device: DeviceDescriptor,
        pids: [Int32]
    ) throws -> AsyncThrowingStream<LogEvent, Error> {
        let output = try adb.stream(.logcatThreadtime(device.serial, pids: pids))
        let pair = AsyncThrowingStream<LogEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8_192)
        )
        let task = Task.detached(priority: .userInitiated) {
            let parser = LogcatParser()
            do {
                for try await item in output {
                    guard case .stdout(let data) = item else { continue }
                    let parsed = await parser.consume(data, receivedAt: Date())
                    for event in parsed {
                        guard case .enqueued = pair.continuation.yield(event) else {
                            throw ProcessRunnerError.outputBufferOverflow
                        }
                    }
                }
                let finalEvents = await parser.finish(receivedAt: Date())
                for event in finalEvents {
                    guard case .enqueued = pair.continuation.yield(event) else {
                        throw ProcessRunnerError.outputBufferOverflow
                    }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return pair.stream
    }
}
