import CryptoKit
import Foundation

enum ScrcpyAvailability: Sendable, Equatable {
    case installRequired
    case available(version: String, managed: Bool)
}

enum ScrcpyManagerError: Error, Equatable {
    case downloadFailed
    case checksumMismatch
    case invalidArchive
    case installFailed
    case launchFailed
    case alreadyRunning
}

actor ScrcpyManager {
    static let version = "4.1"
    static let officialURL = URL(
        string: "https://github.com/Genymobile/scrcpy/releases/download/v4.1/scrcpy-macos-aarch64-v4.1.tar.gz"
    )!
    static let officialSHA256 = "20fd47c9014dd5e0fa77091f3cb7adbda8445a360c4584aeaa0150b5b3988ff3"
    static let projectURL = URL(string: "https://github.com/Genymobile/scrcpy")!

    private static let archiveRoot = "scrcpy-macos-aarch64-v4.1"
    private static let requiredFiles = [
        "scrcpy",
        "scrcpy-server",
        "LICENSE",
        "scrcpy.png",
        "disconnected.png"
    ]

    private let adbURL: URL
    private let rootDirectory: URL
    private let downloader: any DownloadClient
    private let runner: any ProcessRunning
    private let files: FileManager
    private let systemSearchPaths: [String]
    private let registry = ScrcpyProcessRegistry()

    static func production(adbURL: URL) throws -> ScrcpyManager {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ScrcpyManagerError.installFailed
        }
        return ScrcpyManager(
            adbURL: adbURL,
            rootDirectory: support.appendingPathComponent(
                "FantaLogcat/ScrcpyTools",
                isDirectory: true
            ),
            downloader: URLSessionDownloadClient(),
            runner: FoundationProcessRunner()
        )
    }

    init(
        adbURL: URL,
        rootDirectory: URL,
        downloader: any DownloadClient,
        runner: any ProcessRunning,
        files: FileManager = .default,
        systemSearchPaths: [String] = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
    ) {
        self.adbURL = adbURL
        self.rootDirectory = rootDirectory
        self.downloader = downloader
        self.runner = runner
        self.files = files
        self.systemSearchPaths = systemSearchPaths
    }

    func availability() -> ScrcpyAvailability {
        if managedExecutable() != nil {
            return .available(version: Self.version, managed: true)
        }
        if systemExecutable() != nil {
            return .available(version: "system", managed: false)
        }
        return .installRequired
    }

    func install() async throws {
        let temporary = rootDirectory.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? files.removeItem(at: temporary) }

        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: true)
            let archive = temporary.appendingPathComponent("scrcpy.tar.gz")
            let receipt = try await downloader.download(
                from: Self.officialURL,
                to: archive,
                maximumBytes: 20_000_000
            )
            guard receipt.sha256 == Self.officialSHA256 else {
                throw ScrcpyManagerError.checksumMismatch
            }

            let candidate = temporary.appendingPathComponent("candidate", isDirectory: true)
            try files.createDirectory(at: candidate, withIntermediateDirectories: true)
            try await extractRequiredFiles(from: archive, to: candidate)
            try files.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: candidate.appendingPathComponent("scrcpy").path
            )

            let destination = managedDirectory()
            try files.createDirectory(
                at: rootDirectory.appendingPathComponent("versions", isDirectory: true),
                withIntermediateDirectories: true
            )
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.moveItem(at: candidate, to: destination)
            guard managedExecutable() != nil else {
                throw ScrcpyManagerError.installFailed
            }
        } catch let error as ScrcpyManagerError {
            throw error
        } catch {
            throw ScrcpyManagerError.installFailed
        }
    }

    func launch(on device: DeviceDescriptor) throws {
        guard !registry.isRunning(for: device.serial.value) else {
            throw ScrcpyManagerError.alreadyRunning
        }
        guard let executable = managedExecutable() ?? systemExecutable() else {
            throw ScrcpyManagerError.installFailed
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--serial=\(device.serial.value)"]
        var environment = ProcessInfo.processInfo.environment
        environment["ADB"] = adbURL.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        registry.retain(process, for: device.serial.value)
        do {
            try process.run()
            registry.startMonitoring(process, for: device.serial.value)
        } catch {
            registry.release(process, for: device.serial.value)
            throw ScrcpyManagerError.launchFailed
        }
    }

    func isRunning(on device: DeviceDescriptor) -> Bool {
        registry.isRunning(for: device.serial.value)
    }

    func stop(on device: DeviceDescriptor) {
        registry.terminate(for: device.serial.value)
    }

    private func extractRequiredFiles(from archive: URL, to destination: URL) async throws {
        let listing = try await runTar(["-tf", archive.path], timeout: .seconds(20))
        let entries = String(decoding: listing.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard entries.allSatisfy(Self.isSafeArchivePath) else {
            throw ScrcpyManagerError.invalidArchive
        }

        for file in Self.requiredFiles {
            let source = "\(Self.archiveRoot)/\(file)"
            guard entries.contains(source) else {
                throw ScrcpyManagerError.invalidArchive
            }
            let metadata = try await runTar(
                ["-tvf", archive.path, source],
                timeout: .seconds(15)
            )
            guard metadata.stdout.first == 0x2D else {
                throw ScrcpyManagerError.invalidArchive
            }
            let extracted = try await runTar(
                ["-xOf", archive.path, source],
                timeout: .seconds(60)
            )
            guard !extracted.stdout.isEmpty else {
                throw ScrcpyManagerError.invalidArchive
            }
            try extracted.stdout.write(
                to: destination.appendingPathComponent(file),
                options: .atomic
            )
        }
    }

    private func runTar(_ arguments: [String], timeout: Duration) async throws -> ProcessResult {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: arguments,
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw ScrcpyManagerError.invalidArchive
        }
        return result
    }

    private func managedDirectory() -> URL {
        rootDirectory
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(Self.version, isDirectory: true)
    }

    private func managedExecutable() -> URL? {
        let directory = managedDirectory().standardizedFileURL
        let executable = directory.appendingPathComponent("scrcpy")
        guard Self.requiredFiles.allSatisfy({ file in
            let url = directory.appendingPathComponent(file).standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                  ]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }), files.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        return executable
    }

    private func systemExecutable() -> URL? {
        systemSearchPaths.lazy
            .map(URL.init(fileURLWithPath:))
            .first(where: { files.isExecutableFile(atPath: $0.path) })
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

private final class ScrcpyProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [String: Process] = [:]

    func retain(_ process: Process, for serial: String) {
        lock.withLock { processes[serial] = process }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.lock.withLock {
                guard self.processes[serial] === process else { return }
                _ = self.processes.removeValue(forKey: serial)
            }
        }
    }

    func startMonitoring(_ process: Process, for serial: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.waitForExit(process, for: serial)
        }
    }

    func release(_ process: Process, for serial: String) {
        lock.withLock {
            guard processes[serial] === process else { return }
            _ = processes.removeValue(forKey: serial)
        }
    }

    func isRunning(for serial: String) -> Bool {
        lock.withLock {
            guard let process = processes[serial] else { return false }
            if process.isRunning { return true }
            _ = processes.removeValue(forKey: serial)
            return false
        }
    }

    func terminate(for serial: String) {
        let process = lock.withLock { processes[serial] }
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func waitForExit(_ process: Process, for serial: String) {
        guard lock.withLock({ processes[serial] === process }) else { return }
        process.waitUntilExit()
        release(process, for: serial)
    }
}
