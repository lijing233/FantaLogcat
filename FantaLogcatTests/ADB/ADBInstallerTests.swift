import CryptoKit
import Foundation
import XCTest
@testable import FantaLogcat

final class ADBInstallerTests: XCTestCase {
    func testBundledManifestDecodesToPinnedOfficialRelease() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ADBManifest", withExtension: "json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let manifest = try decoder.decode(ADBManifest.self, from: Data(contentsOf: url))

        XCTAssertEqual(manifest.platformToolsVersion, "37.0.0")
        XCTAssertEqual(manifest.archiveBytes, 16_442_240)
        XCTAssertEqual(manifest.downloadURL.host, "dl.google.com")
        XCTAssertEqual(manifest.sha256, "094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7")
    }

    func testLicenseRefusalPerformsNoDownload() async throws {
        let fixture = try InstallerFixture()
        let installer = fixture.makeInstaller(manifest: .fixture(bytes: Data("archive".utf8)))

        do {
            _ = try await installer.install(acceptingLicense: false)
            XCTFail("Expected license refusal")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .licenseNotAccepted)
        }

        let requestCount = await fixture.downloader.requestCount
        let state = await installer.state()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(state, .notInstalled)
    }

    func testChecksumMismatchNeverReplacesWorkingInstallation() async throws {
        let fixture = try InstallerFixture(existingVersion: "36.0.2")
        let manifest = ADBManifest.fixture(
            bytes: Data("bad".utf8),
            sha256: String(repeating: "0", count: 64)
        )
        let installer = fixture.makeInstaller(manifest: manifest)

        do {
            _ = try await installer.install(acceptingLicense: true)
            XCTFail("Expected checksum mismatch")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .checksumMismatch)
        }

        let state = await installer.state()
        XCTAssertEqual(state.installation?.version, "36.0.2")
        XCTAssertEqual(try fixture.candidateNames(), [])
    }

    func testSuccessfulInstallCanRollbackToPreviousVersion() async throws {
        let bytes = Data("valid archive".utf8)
        let fixture = try InstallerFixture(existingVersion: "36.0.2", downloadedBytes: bytes)
        let installer = fixture.makeInstaller(manifest: .fixture(bytes: bytes))

        let installed = try await installer.install(acceptingLicense: true)

        XCTAssertEqual(installed.version, "37.0.0")
        let installedState = await installer.state()
        XCTAssertEqual(installedState.installation?.version, "37.0.0")
        let rolledBack = try await installer.rollback()
        XCTAssertEqual(rolledBack.version, "36.0.2")
        let rolledBackState = await installer.state()
        XCTAssertEqual(rolledBackState.installation?.version, "36.0.2")
    }

    func testTamperedExecutableIsNotReportedAsReady() async throws {
        let bytes = Data("valid archive".utf8)
        let fixture = try InstallerFixture(downloadedBytes: bytes)
        let installer = fixture.makeInstaller(manifest: .fixture(bytes: bytes))
        let installed = try await installer.install(acceptingLicense: true)
        try Data("truncated".utf8).write(to: installed.executableURL)

        let state = await installer.state()

        XCTAssertEqual(state, .notInstalled)
    }

    func testVerificationFailurePreservesWorkingInstallation() async throws {
        let bytes = Data("valid archive".utf8)
        let fixture = try InstallerFixture(
            existingVersion: "36.0.2",
            downloadedBytes: bytes,
            verificationError: .verificationFailed
        )
        let installer = fixture.makeInstaller(manifest: .fixture(bytes: bytes))

        do {
            _ = try await installer.install(acceptingLicense: true)
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .verificationFailed)
        }

        let state = await installer.state()
        XCTAssertEqual(state.installation?.version, "36.0.2")
    }

    func testCorruptActiveVersionCannotEscapeVersionsDirectory() async throws {
        let fixture = try InstallerFixture(existingVersion: "36.0.2")
        let pointer = #"{"activeVersion":"../../Applications","previousVersion":null}"#
        try Data(pointer.utf8).write(to: fixture.root.appendingPathComponent("active.json"))
        let installer = fixture.makeInstaller(manifest: .fixture(bytes: Data("archive".utf8)))

        let state = await installer.state()

        XCTAssertEqual(state, .notInstalled)
    }

    func testRollbackIsRejectedWhileInstallIsSuspended() async throws {
        let bytes = Data("valid archive".utf8)
        let fixture = try InstallerFixture(existingVersion: "36.0.2", downloadedBytes: bytes)
        let downloader = BlockingDownloadClient(bytes: bytes)
        let installer = fixture.makeInstaller(
            manifest: .fixture(bytes: bytes),
            downloader: downloader
        )
        let installTask = Task {
            try await installer.install(acceptingLicense: true)
        }
        await downloader.waitUntilStarted()

        do {
            _ = try await installer.rollback()
            XCTFail("Expected install-in-progress error")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .installInProgress)
        }

        await downloader.resume()
        _ = try await installTask.value
    }
}

private final class InstallerFixture {
    let root: URL
    let downloader: RecordingDownloadClient
    private let files = FileManager.default
    private let extractor = FixtureArchiveExtractor()
    private let verifier: FixtureADBVerifier

    init(
        existingVersion: String? = nil,
        downloadedBytes: Data = Data("bad".utf8),
        verificationError: ADBInstallerError? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FantaLogcatTests-\(UUID().uuidString)", isDirectory: true)
        downloader = RecordingDownloadClient(bytes: downloadedBytes)
        verifier = FixtureADBVerifier(error: verificationError)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        if let existingVersion {
            let directory = root.appendingPathComponent("versions/\(existingVersion)", isDirectory: true)
            try files.createDirectory(
                at: directory.appendingPathComponent("lib64", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("old adb".utf8).write(to: directory.appendingPathComponent("adb"))
            try files.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.appendingPathComponent("adb").path
            )
            try Data("dylib".utf8).write(to: directory.appendingPathComponent("lib64/libc++.dylib"))
            try Data("properties".utf8).write(to: directory.appendingPathComponent("source.properties"))
            try Data("notice".utf8).write(to: directory.appendingPathComponent("NOTICE.txt"))
            let requiredFiles = [
                "adb", "lib64/libc++.dylib", "source.properties", "NOTICE.txt"
            ]
            let hashes = try Dictionary(uniqueKeysWithValues: requiredFiles.map { path in
                let data = try Data(contentsOf: directory.appendingPathComponent(path))
                return (path, digest(data))
            })
            let metadata: [String: Any] = [
                "schemaVersion": 2,
                "version": existingVersion,
                "sha256": String(repeating: "0", count: 64),
                "fileHashes": hashes
            ]
            try JSONSerialization.data(withJSONObject: metadata).write(
                to: directory.appendingPathComponent("installation.json")
            )
            let pointer = #"{"activeVersion":"\#(existingVersion)","previousVersion":null}"#
            try Data(pointer.utf8).write(to: root.appendingPathComponent("active.json"))
        }
    }

    deinit {
        try? files.removeItem(at: root)
    }

    func makeInstaller(
        manifest: ADBManifest,
        downloader: (any DownloadClient)? = nil
    ) -> ADBInstaller {
        ADBInstaller(
            manifest: manifest,
            rootDirectory: root,
            downloader: downloader ?? self.downloader,
            extractor: extractor,
            verifier: verifier
        )
    }

    func candidateNames() throws -> [String] {
        try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".install-") }
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private actor RecordingDownloadClient: DownloadClient {
    private(set) var requestCount = 0
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws -> DownloadReceipt {
        requestCount += 1
        try bytes.write(to: destination, options: .atomic)
        return DownloadReceipt(
            byteCount: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private actor BlockingDownloadClient: DownloadClient {
    let bytes: Data
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(bytes: Data) {
        self.bytes = bytes
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        if let releaseContinuation {
            releaseContinuation.resume()
            self.releaseContinuation = nil
        } else {
            released = true
        }
    }

    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws -> DownloadReceipt {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        try bytes.write(to: destination, options: .atomic)
        return DownloadReceipt(
            byteCount: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private struct FixtureArchiveExtractor: ArchiveExtracting {
    func extractRequiredFiles(from archiveURL: URL, to destination: URL) async throws {
        let files = FileManager.default
        try files.createDirectory(
            at: destination.appendingPathComponent("lib64", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("adb".utf8).write(to: destination.appendingPathComponent("adb"))
        try Data("dylib".utf8).write(to: destination.appendingPathComponent("lib64/libc++.dylib"))
        try Data("properties".utf8).write(to: destination.appendingPathComponent("source.properties"))
        try Data("notice".utf8).write(to: destination.appendingPathComponent("NOTICE.txt"))
    }
}

private struct FixtureADBVerifier: ADBVersionVerifying {
    let error: ADBInstallerError?

    func verify(executableURL: URL, expectedVersion: String) async throws {
        if let error { throw error }
    }
}

private extension ADBManifest {
    static func fixture(
        bytes: Data,
        sha256: String? = nil
    ) -> ADBManifest {
        ADBManifest(
            schemaVersion: 1,
            platformToolsVersion: "37.0.0",
            downloadURL: URL(string: "https://dl.google.com/android/repository/platform-tools.zip")!,
            archiveBytes: bytes.count,
            sha256: sha256 ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            licenseURL: URL(string: "https://developer.android.com/studio/terms")!,
            verifiedAt: Date(timeIntervalSince1970: 1_786_406_400)
        )!
    }
}
