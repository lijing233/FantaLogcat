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
    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws -> DownloadReceipt
}

struct DownloadReceipt: Sendable, Equatable {
    let byteCount: Int
    let sha256: String
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

    private struct InstallationMetadata: Codable {
        let schemaVersion: Int
        let version: String
        let sha256: String
        let fileHashes: [String: String]
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
            let archiveURL = temporary.appendingPathComponent("platform-tools.zip")
            let receipt = try await downloader.download(
                from: manifest.downloadURL,
                to: archiveURL,
                maximumBytes: maximumBytes
            )
            guard receipt.byteCount <= maximumBytes else { throw ADBInstallerError.archiveTooLarge }
            guard receipt.sha256 == manifest.sha256 else {
                throw ADBInstallerError.checksumMismatch
            }

            let candidate = temporary.appendingPathComponent("candidate", isDirectory: true)
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
            let fileHashes = try Dictionary(uniqueKeysWithValues: Self.requiredPaths.map {
                ($0, try Self.sha256(of: candidate.appendingPathComponent($0)))
            })
            let metadata = InstallationMetadata(
                schemaVersion: 2,
                version: manifest.platformToolsVersion,
                sha256: manifest.sha256,
                fileHashes: fileHashes
            )
            try JSONEncoder().encode(metadata).write(
                to: candidate.appendingPathComponent("installation.json"),
                options: .atomic
            )

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
        guard !isInstalling else { throw ADBInstallerError.installInProgress }
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
        guard Self.isValidVersion(version) else { return nil }
        let versions = rootDirectory.appendingPathComponent("versions", isDirectory: true)
            .standardizedFileURL
        let directory = versions.appendingPathComponent(version, isDirectory: true)
            .standardizedFileURL
        guard directory.path.hasPrefix(versions.path + "/"),
              let metadataData = try? Data(contentsOf: directory.appendingPathComponent("installation.json")),
              let metadata = try? JSONDecoder().decode(InstallationMetadata.self, from: metadataData),
              metadata.schemaVersion == 2,
              metadata.version == version,
              metadata.sha256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil,
              version != manifest.platformToolsVersion || metadata.sha256 == manifest.sha256,
              Set(metadata.fileHashes.keys) == Set(Self.requiredPaths) else {
            return nil
        }
        for relativePath in Self.requiredPaths {
            let url = directory.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let expectedHash = metadata.fileHashes[relativePath],
                  expectedHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let actualHash = try? Self.sha256(of: url),
                  actualHash == expectedHash else {
                return nil
            }
        }
        let executable = directory.appendingPathComponent("adb")
        guard files.isExecutableFile(atPath: executable.path) else { return nil }
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

    private static func isValidVersion(_ version: String) -> Bool {
        version.range(
            of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:[-+][A-Za-z0-9.-]+)?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct URLSessionDownloadClient: DownloadClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws -> DownloadReceipt {
        let (bytes, response) = try await session.bytes(from: url)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw ADBInstallerError.archiveTooLarge
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var count = 0

        func flush() throws {
            guard !buffer.isEmpty else { return }
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        for try await byte in bytes {
            count += 1
            guard count <= maximumBytes else { throw ADBInstallerError.archiveTooLarge }
            buffer.append(byte)
            if buffer.count == 64 * 1_024 { try flush() }
        }
        try flush()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return DownloadReceipt(byteCount: count, sha256: hash)
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
