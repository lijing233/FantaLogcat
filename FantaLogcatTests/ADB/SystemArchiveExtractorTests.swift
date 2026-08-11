import Foundation
import XCTest
@testable import FantaLogcat

final class SystemArchiveExtractorTests: XCTestCase {
    func testRejectsTraversalBeforeExtractingAnyEntry() async throws {
        let runner = ArchiveRunner(
            listing: requiredPaths.joined(separator: "\n") + "\n../escape\n"
        )
        let extractor = SystemArchiveExtractor(runner: runner)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveExtractor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await extractor.extractRequiredFiles(
                from: URL(fileURLWithPath: "/fixture.zip"),
                to: destination
            )
            XCTFail("Expected invalid archive")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .invalidArchive)
        }

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsRequiredSymlinkEntry() async throws {
        let runner = ArchiveRunner(
            listing: requiredPaths.joined(separator: "\n"),
            metadataPrefix: "l"
        )
        let extractor = SystemArchiveExtractor(runner: runner)

        do {
            try await extractor.extractRequiredFiles(
                from: URL(fileURLWithPath: "/fixture.zip"),
                to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("ArchiveExtractor-\(UUID().uuidString)")
            )
            XCTFail("Expected invalid archive")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .invalidArchive)
        }
    }
}

private let requiredPaths = [
    "platform-tools/adb",
    "platform-tools/lib64/libc++.dylib",
    "platform-tools/source.properties",
    "platform-tools/NOTICE.txt"
]

private final class ArchiveRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let listing: String
    private let metadataPrefix: String
    private var storedInvocations: [[String]] = []

    init(listing: String, metadataPrefix: String = "-") {
        self.listing = listing
        self.metadataPrefix = metadataPrefix
    }

    var invocations: [[String]] {
        lock.withLock { storedInvocations }
    }

    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult {
        lock.withLock { storedInvocations.append(arguments) }
        if arguments.first == "-tf" {
            return .success(stdout: listing)
        }
        if arguments.first == "-tvf" {
            return .success(stdout: metadataPrefix + "rw-r--r-- fixture")
        }
        return .success(stdout: "file contents")
    }

    func stream(
        executable: URL,
        arguments: [String]
    ) throws -> AsyncThrowingStream<ProcessOutput, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
