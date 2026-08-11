import Foundation

enum ADBError: Error, Equatable {
    case commandFailed(exitCode: Int32, stderrSummary: String)
}

protocol ADBRuntimeProtocol: Sendable {
    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult
    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error>
}

struct ADBRuntime: ADBRuntimeProtocol, Sendable {
    private let executableURL: URL
    private let runner: any ProcessRunning
    private let maximumErrorBytes: Int

    init(
        executableURL: URL,
        runner: any ProcessRunning,
        maximumErrorBytes: Int = 2_048
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.maximumErrorBytes = max(0, maximumErrorBytes)
    }

    func run(_ command: ADBCommand, timeout: Duration) async throws -> ProcessResult {
        let result = try await runner.run(
            executable: executableURL,
            arguments: command.arguments,
            timeout: timeout
        )
        guard result.exitCode != 0 else { return result }
        throw ADBError.commandFailed(
            exitCode: result.exitCode,
            stderrSummary: Self.limitedString(
                result.stderr,
                redacting: command.sensitiveValues,
                maximumBytes: maximumErrorBytes
            )
        )
    }

    func stream(_ command: ADBCommand) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        try runner.stream(executable: executableURL, arguments: command.arguments)
    }

    private static func limitedString(
        _ data: Data,
        redacting sensitiveValues: [String],
        maximumBytes: Int
    ) -> String {
        guard maximumBytes > 0 else { return "" }
        let decoded = sensitiveValues.reduce(String(decoding: data, as: UTF8.self)) { text, secret in
            text.replacingOccurrences(of: secret, with: "<redacted>")
        }
        var result = ""
        result.reserveCapacity(min(maximumBytes, decoded.utf8.count))
        for character in decoded {
            guard result.utf8.count + character.utf8.count <= maximumBytes else { break }
            result.append(character)
        }
        return result
    }
}
