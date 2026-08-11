import Foundation

struct AppEnvironment: Sendable {
    let makeADBInstaller: @Sendable () throws -> any ADBInstalling
    let adbLicenseURL: URL

    static let production = AppEnvironment(
        makeADBInstaller: {
            guard let manifestURL = Bundle.main.url(
                forResource: "ADBManifest",
                withExtension: "json"
            ) else {
                throw ADBInstallerError.fileOperationFailed
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(
                ADBManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            let root = try applicationSupportDirectory()
                .appendingPathComponent("FantaLogcat/AndroidTools", isDirectory: true)
            let runner = FoundationProcessRunner()
            return ADBInstaller(
                manifest: manifest,
                rootDirectory: root,
                downloader: URLSessionDownloadClient(),
                extractor: SystemArchiveExtractor(runner: runner),
                verifier: RuntimeADBVersionVerifier(runner: runner)
            )
        },
        adbLicenseURL: URL(string: "https://developer.android.com/studio/terms")!
    )

    static func test(installer: (any ADBInstalling)? = nil) -> AppEnvironment {
        let resolved = installer ?? TestADBInstaller()
        return AppEnvironment(
            makeADBInstaller: { resolved },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        )
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let url = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ADBInstallerError.fileOperationFailed
        }
        return url
    }
}

private actor TestADBInstaller: ADBInstalling {
    func state() -> ADBInstallationState { .notInstalled }
    func install(acceptingLicense: Bool) throws -> ADBInstallation {
        throw ADBInstallerError.licenseNotAccepted
    }
    func rollback() throws -> ADBInstallation {
        throw ADBInstallerError.noRollbackAvailable
    }
}
