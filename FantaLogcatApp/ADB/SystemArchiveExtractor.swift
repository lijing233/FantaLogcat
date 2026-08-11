import Foundation

struct SystemArchiveExtractor: ArchiveExtracting {
    private static let sourceToDestination = [
        "platform-tools/adb": "adb",
        "platform-tools/lib64/libc++.dylib": "lib64/libc++.dylib",
        "platform-tools/source.properties": "source.properties",
        "platform-tools/NOTICE.txt": "NOTICE.txt"
    ]

    let runner: any ProcessRunning
    let tarURL: URL

    init(
        runner: any ProcessRunning,
        tarURL: URL = URL(fileURLWithPath: "/usr/bin/tar")
    ) {
        self.runner = runner
        self.tarURL = tarURL
    }

    func extractRequiredFiles(from archiveURL: URL, to destination: URL) async throws {
        let listing = try await run(["-tf", archiveURL.path])
        let paths = String(decoding: listing.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard paths.allSatisfy(Self.isSafeArchivePath),
              Set(Self.sourceToDestination.keys).isSubset(of: Set(paths)) else {
            throw ADBInstallerError.invalidArchive
        }

        let files = FileManager.default
        for (source, relativeDestination) in Self.sourceToDestination {
            let metadata = try await run(["-tvf", archiveURL.path, source])
            guard metadata.stdout.first == 0x2D else {
                throw ADBInstallerError.invalidArchive
            }
            let extracted = try await run(["-xOf", archiveURL.path, source])
            guard !extracted.stdout.isEmpty else { throw ADBInstallerError.invalidArchive }
            let outputURL = destination.appendingPathComponent(relativeDestination)
            try files.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try extracted.stdout.write(to: outputURL, options: .atomic)
        }
    }

    private func run(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await runner.run(
            executable: tarURL,
            arguments: arguments,
            timeout: .seconds(15)
        )
        guard result.exitCode == 0 else { throw ADBInstallerError.invalidArchive }
        return result
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
