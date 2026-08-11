import CryptoKit
import Foundation
import XCTest
@testable import FantaLogcat

final class ADBInstallerTests: XCTestCase {
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
}

private final class InstallerFixture {
    let root: URL
    let downloader: RecordingDownloadClient
    private let files = FileManager.default
    private let extractor = FixtureArchiveExtractor()
    private let verifier = FixtureADBVerifier()

    init(existingVersion: String? = nil, downloadedBytes: Data = Data("bad".utf8)) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FantaLogcatTests-\(UUID().uuidString)", isDirectory: true)
        downloader = RecordingDownloadClient(bytes: downloadedBytes)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        if let existingVersion {
            let directory = root.appendingPathComponent("versions/\(existingVersion)", isDirectory: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("old adb".utf8).write(to: directory.appendingPathComponent("adb"))
            let pointer = #"{"activeVersion":"\#(existingVersion)","previousVersion":null}"#
            try Data(pointer.utf8).write(to: root.appendingPathComponent("active.json"))
        }
    }

    deinit {
        try? files.removeItem(at: root)
    }

    func makeInstaller(manifest: ADBManifest) -> ADBInstaller {
        ADBInstaller(
            manifest: manifest,
            rootDirectory: root,
            downloader: downloader,
            extractor: extractor,
            verifier: verifier
        )
    }

    func candidateNames() throws -> [String] {
        try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".install-") }
    }
}

private actor RecordingDownloadClient: DownloadClient {
    private(set) var requestCount = 0
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        requestCount += 1
        return bytes
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
    func verify(executableURL: URL, expectedVersion: String) async throws {}
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
