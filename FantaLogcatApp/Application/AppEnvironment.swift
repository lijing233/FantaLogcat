import Foundation

struct AppEnvironment: Sendable {
    let makeADBInstaller: @Sendable () throws -> any ADBInstalling
    let makeDeviceService: @Sendable (ADBInstallation) -> any DeviceServiceProtocol
    let makeAppCatalog: @Sendable (ADBInstallation) -> any AppCatalogProtocol
    let makeLogSession: @Sendable (ADBInstallation) -> any LogSessionProtocol
    let makeWirelessService: @Sendable (ADBInstallation) -> any WirelessDebugServiceProtocol
    let makeAppSelectionStore: @Sendable () -> any AppSelectionStoreProtocol
    let adbLicenseURL: URL

    init(
        makeADBInstaller: @escaping @Sendable () throws -> any ADBInstalling,
        makeDeviceService: @escaping @Sendable (ADBInstallation) -> any DeviceServiceProtocol,
        makeAppCatalog: @escaping @Sendable (ADBInstallation) -> any AppCatalogProtocol,
        makeLogSession: @escaping @Sendable (ADBInstallation) -> any LogSessionProtocol,
        makeWirelessService: @escaping @Sendable (ADBInstallation) -> any WirelessDebugServiceProtocol = { installation in
            WirelessDebugService(adb: ADBRuntime(
                executableURL: installation.executableURL,
                runner: FoundationProcessRunner()
            ))
        },
        makeAppSelectionStore: @escaping @Sendable () -> any AppSelectionStoreProtocol,
        adbLicenseURL: URL
    ) {
        self.makeADBInstaller = makeADBInstaller
        self.makeDeviceService = makeDeviceService
        self.makeAppCatalog = makeAppCatalog
        self.makeLogSession = makeLogSession
        self.makeWirelessService = makeWirelessService
        self.makeAppSelectionStore = makeAppSelectionStore
        self.adbLicenseURL = adbLicenseURL
    }

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
        makeDeviceService: { installation in
            DeviceService(adb: ADBRuntime(
                executableURL: installation.executableURL,
                runner: FoundationProcessRunner()
            ))
        },
        makeAppCatalog: { installation in
            AppCatalog(adb: ADBRuntime(executableURL: installation.executableURL, runner: FoundationProcessRunner()))
        },
        makeLogSession: { installation in
            LogSession(adb: ADBRuntime(executableURL: installation.executableURL, runner: FoundationProcessRunner()))
        },
        makeAppSelectionStore: { UserDefaultsAppSelectionStore() },
        adbLicenseURL: URL(string: "https://developer.android.com/studio/terms")!
    )

    static func test(
        installer: (any ADBInstalling)? = nil,
        deviceService: (any DeviceServiceProtocol)? = nil,
        appCatalog: (any AppCatalogProtocol)? = nil,
        logSession: (any LogSessionProtocol)? = nil,
        wirelessService: (any WirelessDebugServiceProtocol)? = nil,
        appSelectionStore: (any AppSelectionStoreProtocol)? = nil
    ) -> AppEnvironment {
        let resolved = installer ?? TestADBInstaller()
        let resolvedDeviceService = deviceService ?? TestDeviceService()
        let resolvedAppCatalog = appCatalog ?? TestAppCatalog()
        let resolvedLogSession = logSession ?? TestLogSession()
        let resolvedWirelessService = wirelessService ?? TestWirelessDebugService()
        let resolvedAppSelectionStore = appSelectionStore ?? TestAppSelectionStore()
        return AppEnvironment(
            makeADBInstaller: { resolved },
            makeDeviceService: { _ in resolvedDeviceService },
            makeAppCatalog: { _ in resolvedAppCatalog },
            makeLogSession: { _ in resolvedLogSession },
            makeWirelessService: { _ in resolvedWirelessService },
            makeAppSelectionStore: { resolvedAppSelectionStore },
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

private actor TestAppCatalog: AppCatalogProtocol {
    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor] { [] }
    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor] { [] }
}

private actor TestDeviceService: DeviceServiceProtocol {
    func refresh() async throws -> DeviceConnectionState { .noDevice }
}

private struct TestLogSession: LogSessionProtocol {
    func events(on device: DeviceDescriptor, pids: [Int32]) throws -> AsyncThrowingStream<LogEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor TestWirelessDebugService: WirelessDebugServiceProtocol {
    func mDNSAvailable() async -> Bool { false }
    func discoverPairingEndpoint(serviceName: String) async throws -> ADBEndpoint? { nil }
    func pair(endpoint: ADBEndpoint, secret: String) async throws {}
    func connect(endpoint: ADBEndpoint) async throws {}
    func enableTCPIP(serial: ADBDeviceSerial, port: Int) async throws {}
    func restoreUSB(serial: ADBDeviceSerial) async throws {}
    func disconnect(address: String?) async throws {}
    func restartServer() async throws {}
    func wifiIPAddress(serial: ADBDeviceSerial) async throws -> String? { nil }
}

private final class TestAppSelectionStore: AppSelectionStoreProtocol, @unchecked Sendable {
    var preferences: AppSelectionPreferences { .empty }
    func toggleFavorite(_ packageName: String) -> Bool { true }
    func recordRecent(_ packageName: String) {}
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
