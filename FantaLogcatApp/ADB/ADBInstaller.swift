import CryptoKit
import Foundation

struct ADBInstallation: Codable, Sendable, Equatable {
    let version: String
    let executableURL: URL
}

enum ADBInstallationState: Sendable, Equatable {
    case notInstalled
    case ready(ADBInstallation)

    var installation: ADBInstallation? {
        guard case .ready(let installation) = self else { return nil }
        return installation
    }
}

enum ADBInstallerError: Error, Equatable {
    case licenseNotAccepted
    case installInProgress
    case archiveTooLarge
    case checksumMismatch
    case invalidArchive
    case verificationFailed
    case noRollbackAvailable
    case fileOperationFailed

    var code: String {
        switch self {
        case .licenseNotAccepted: "license_not_accepted"
        case .installInProgress: "install_in_progress"
        case .archiveTooLarge: "archive_too_large"
        case .checksumMismatch: "checksum_mismatch"
        case .invalidArchive: "invalid_archive"
        case .verificationFailed: "verification_failed"
        case .noRollbackAvailable: "no_rollback_available"
        case .fileOperationFailed: "file_operation_failed"
        }
    }
}

protocol DownloadClient: Sendable {
    func download(from url: URL, maximumBytes: Int) async throws -> Data
}

protocol ArchiveExtracting: Sendable {
    func extractRequiredFiles(from archiveURL: URL, to destination: URL) async throws
}

protocol ADBVersionVerifying: Sendable {
    func verify(executableURL: URL, expectedVersion: String) async throws
}

protocol ADBInstalling: Sendable {
    func state() async -> ADBInstallationState
    func install(acceptingLicense: Bool) async throws -> ADBInstallation
    func rollback() async throws -> ADBInstallation
}

actor ADBInstaller: ADBInstalling {
    private struct ActivePointer: Codable {
        let activeVersion: String
        let previousVersion: String?
    }

    private static let requiredPaths = [
        "adb",
        "lib64/libc++.dylib",
        "source.properties",
        "NOTICE.txt"
    ]

    private let manifest: ADBManifest
    private let rootDirectory: URL
    private let downloader: any DownloadClient
    private let extractor: any ArchiveExtracting
    private let verifier: any ADBVersionVerifying
    private let files: FileManager
    private var isInstalling = false

    init(
        manifest: ADBManifest,
        rootDirectory: URL,
        downloader: any DownloadClient,
        extractor: any ArchiveExtracting,
        verifier: any ADBVersionVerifying,
        files: FileManager = .default
    ) {
        self.manifest = manifest
        self.rootDirectory = rootDirectory
        self.downloader = downloader
        self.extractor = extractor
        self.verifier = verifier
        self.files = files
    }

    func state() -> ADBInstallationState {
        guard let pointer = try? readPointer(),
              let installation = installation(for: pointer.activeVersion) else {
            return .notInstalled
        }
        return .ready(installation)
    }

    func install(acceptingLicense: Bool) async throws -> ADBInstallation {
        guard acceptingLicense else { throw ADBInstallerError.licenseNotAccepted }
        guard !isInstalling else { throw ADBInstallerError.installInProgress }
        if case .ready(let installation) = state(), installation.version == manifest.platformToolsVersion {
            return installation
        }

        isInstalling = true
        defer { isInstalling = false }

        let previousVersion = state().installation?.version
        let temporary = rootDirectory.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? files.removeItem(at: temporary) }

        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: true)
            let maximumBytes = Int(ceil(Double(manifest.archiveBytes) * 1.01))
            let archive = try await downloader.download(
                from: manifest.downloadURL,
                maximumBytes: maximumBytes
            )
            guard archive.count <= maximumBytes else { throw ADBInstallerError.archiveTooLarge }
            guard Self.sha256(archive) == manifest.sha256 else {
                throw ADBInstallerError.checksumMismatch
            }

            let archiveURL = temporary.appendingPathComponent("platform-tools.zip")
            let candidate = temporary.appendingPathComponent("candidate", isDirectory: true)
            try archive.write(to: archiveURL, options: .atomic)
            try files.createDirectory(at: candidate, withIntermediateDirectories: true)
            try await extractor.extractRequiredFiles(from: archiveURL, to: candidate)
            try validateCandidate(candidate)

            let executable = candidate.appendingPathComponent("adb")
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            do {
                try await verifier.verify(
                    executableURL: executable,
                    expectedVersion: manifest.platformToolsVersion
                )
            } catch {
                throw ADBInstallerError.verificationFailed
            }

            let versions = rootDirectory.appendingPathComponent("versions", isDirectory: true)
            try files.createDirectory(at: versions, withIntermediateDirectories: true)
            let destination = versions.appendingPathComponent(
                manifest.platformToolsVersion,
                isDirectory: true
            )
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.moveItem(at: candidate, to: destination)
            try writePointer(.init(
                activeVersion: manifest.platformToolsVersion,
                previousVersion: previousVersion
            ))
            guard let installed = installation(for: manifest.platformToolsVersion) else {
                throw ADBInstallerError.fileOperationFailed
            }
            return installed
        } catch let error as ADBInstallerError {
            throw error
        } catch {
            throw ADBInstallerError.fileOperationFailed
        }
    }

    func rollback() throws -> ADBInstallation {
        guard let pointer = try? readPointer(),
              let previous = pointer.previousVersion,
              let installation = installation(for: previous) else {
            throw ADBInstallerError.noRollbackAvailable
        }
        do {
            try writePointer(.init(
                activeVersion: previous,
                previousVersion: pointer.activeVersion
            ))
            return installation
        } catch {
            throw ADBInstallerError.fileOperationFailed
        }
    }

    private func installation(for version: String) -> ADBInstallation? {
        let executable = rootDirectory
            .appendingPathComponent("versions/\(version)", isDirectory: true)
            .appendingPathComponent("adb")
        guard files.isExecutableFile(atPath: executable.path)
            || files.fileExists(atPath: executable.path) else {
            return nil
        }
        return ADBInstallation(version: version, executableURL: executable)
    }

    private func validateCandidate(_ candidate: URL) throws {
        for relativePath in Self.requiredPaths {
            let url = candidate.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true else {
                throw ADBInstallerError.invalidArchive
            }
        }
    }

    private func readPointer() throws -> ActivePointer {
        let data = try Data(contentsOf: rootDirectory.appendingPathComponent("active.json"))
        return try JSONDecoder().decode(ActivePointer.self, from: data)
    }

    private func writePointer(_ pointer: ActivePointer) throws {
        try files.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pointer)
        try data.write(
            to: rootDirectory.appendingPathComponent("active.json"),
            options: .atomic
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct URLSessionDownloadClient: DownloadClient {
    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ADBInstallerError.archiveTooLarge
        }
        guard data.count <= maximumBytes else { throw ADBInstallerError.archiveTooLarge }
        return data
    }
}

struct RuntimeADBVersionVerifier: ADBVersionVerifying {
    let runner: any ProcessRunning

    func verify(executableURL: URL, expectedVersion: String) async throws {
        let runtime = ADBRuntime(executableURL: executableURL, runner: runner)
        let result = try await runtime.run(.version, timeout: .seconds(5))
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        guard output.contains(expectedVersion) else {
            throw ADBInstallerError.verificationFailed
        }
    }
}
