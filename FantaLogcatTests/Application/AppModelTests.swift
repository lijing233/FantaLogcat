import Foundation
import XCTest
@testable import FantaLogcat

@MainActor
final class AppModelTests: XCTestCase {
    func testNewModelStartsInPreparingADBPhase() {
        let model = AppModel(environment: .test())

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .checking)
    }

    func testMissingADBShowsLicenseActionInsteadOfInfiniteProgress() async {
        let installer = AppModelInstaller(initialState: .notInstalled)
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .licenseRequired)
    }

    func testReadyADBAdvancesToDeviceSelection() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let installer = AppModelInstaller(initialState: .ready(installation))
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()

        XCTAssertEqual(model.phase, .selectingDevice)
    }

    func testInstallingADBSucceedsAndAdvances() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let installer = AppModelInstaller(
            initialState: .notInstalled,
            installResult: .success(installation)
        )
        let model = AppModel(environment: .test(installer: installer))

        await model.prepareADB()
        await model.installADB()

        XCTAssertEqual(model.phase, .selectingDevice)
    }

    func testRetryAfterPreparationFailureChecksAgainWithoutInstalling() async {
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { throw ADBInstallerError.fileOperationFailed },
            makeDeviceService: { _ in AppModelDeviceService(state: .noDevice) },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.retryADB()

        XCTAssertEqual(model.phase, .preparingADB)
        XCTAssertEqual(model.adbPreparation, .failed("file_operation_failed"))
    }

    func testRetryAfterAuthorizedInstallFailureRetriesInstallation() async {
        let installer = AppModelInstaller(initialState: .notInstalled)
        let model = AppModel(environment: .test(installer: installer))
        await model.prepareADB()

        await model.installADB()
        await model.retryADB()

        let installCalls = await installer.installCalls
        XCTAssertEqual(installCalls, 2)
        XCTAssertEqual(model.adbPreparation, .failed("checksum_mismatch"))
    }

    func testSingleDeviceAutomaticallyAdvancesToApplicationSelection() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try! ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let model = AppModel(environment: .test(
            installer: AppModelInstaller(initialState: .ready(installation)),
            deviceService: AppModelDeviceService(state: .connected(device))
        ))

        await model.prepareADB()
        await model.refreshDevices()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testConnectionMonitorReturnsToDeviceSelectionAndRecoversAutomatically() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let service = AppModelSequencedDeviceService(states: [.connected(device), .noDevice, .connected(device)])
        let model = AppModel(environment: .test(
            installer: AppModelInstaller(initialState: .ready(installation)),
            deviceService: service
        ))

        await model.prepareADB()
        await model.refreshDevices()
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingDevice)
        XCTAssertEqual(model.deviceConnection, .noDevice)

        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testSelectingAppStartsLogStreamAndPublishesEvents() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let event = LogEvent(
            id: 1,
            deviceTimestamp: nil,
            receivedAt: Date(),
            pid: 42,
            tid: 42,
            priority: .info,
            androidTag: "Unity",
            businessTag: nil,
            message: "ready",
            rawText: "ready",
            parseStatus: .complete,
            packageName: nil,
            processName: nil
        )
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in AppModelAppCatalog(apps: [app], processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]) },
            makeLogSession: { _ in AppModelLogSession(events: [event]) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil { model.logEvents == [event] }

        XCTAssertEqual(model.phase, .viewingLogs)
        XCTAssertEqual(model.logEvents, [event])
    }

    func testSelectingAppPublishesRecentEventsBeforeLiveEvents() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let device = DeviceDescriptor(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb)
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let history = LogEvent.fixture(id: 1, message: "startup")
        let live = LogEvent.fixture(id: 2, message: "ready")
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in AppModelAppCatalog(apps: [app], processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]) },
            makeLogSession: { _ in AppModelLogSession(events: [live], recentEvents: [history]) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil { model.logEvents.map(\.message) == ["startup", "ready"] }

        XCTAssertEqual(model.logEvents.map(\.message), ["startup", "ready"])
    }

    func testSelectingAppEvictsOldLogsWhenTheTextByteLimitIsReached() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let events = [1, 2, 3].map { id in
            LogEvent(
                id: UInt64(id),
                deviceTimestamp: nil,
                receivedAt: Date(),
                pid: 42,
                tid: 42,
                priority: .info,
                androidTag: "Unity",
                businessTag: nil,
                message: "1234",
                rawText: "1234",
                parseStatus: .complete,
                packageName: nil,
                processName: nil
            )
        }
        let model = AppModel(
            environment: AppEnvironment(
                makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
                makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
                makeAppCatalog: { _ in
                    AppModelAppCatalog(
                        apps: [app],
                        processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]
                    )
                },
                makeLogSession: { _ in AppModelLogSession(events: events) },
                makeAppSelectionStore: { InMemoryAppSelectionStore() },
                adbLicenseURL: URL(string: "https://example.com/terms")!
            ),
            cacheLimits: .init(maxEvents: 10, maxTextBytes: 16)
        )

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil { model.logEvents.map(\.id) == [2, 3] }

        XCTAssertEqual(model.logEvents.map(\.id), [2, 3])
    }

    func testPausingPresentationStillRetainsNewEventsUntilResume() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let device = DeviceDescriptor(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb)
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let session = AppModelControlledLogSession()
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in
                AppModelAppCatalog(
                    apps: [app],
                    processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]
                )
            },
            makeLogSession: { _ in session },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil { session.hasSubscriber }
        session.emit(.fixture(id: 1, message: "first"))
        await waitUntil { model.logEvents.map(\.id) == [1] }
        model.pauseLogPresentation()
        session.emit(.fixture(id: 2, message: "later"))
        await waitUntil { model.pendingLogEventCount == 1 }

        XCTAssertEqual(model.logEvents.map(\.id), [1])
        XCTAssertEqual(model.pendingLogEventCount, 1)

        await model.resumeLogPresentation()

        XCTAssertEqual(model.logEvents.map(\.id), [1, 2])
        XCTAssertEqual(model.pendingLogEventCount, 0)
    }

    func testKeywordAndLevelSelectionPublishOnlyMatchingEvents() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let device = DeviceDescriptor(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb)
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let events: [LogEvent] = [
            .fixture(id: 1, priority: .warning, androidTag: "Unity", message: "warning"),
            .fixture(id: 2, priority: .error, androidTag: "SDK", message: "failure"),
            .fixture(id: 3, priority: .error, androidTag: "Unity", message: "failure")
        ]
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in
                AppModelAppCatalog(
                    apps: [app],
                    processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]
                )
            },
            makeLogSession: { _ in AppModelLogSession(events: events) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil { model.logEvents.count == events.count }
        model.setLogLevels([.error])
        model.setLogKeyword("Unity")

        XCTAssertEqual(model.filteredLogEvents.map(\.id), [3])
    }

    func testSelectionRecordsRecentAndFavoriteSectionsOnlyContainInstalledApps() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let tile = AppDescriptor(
            packageName: try AndroidPackageName("com.game.tile"),
            presentation: AppPresentation(displayName: "Tile Match", symbolName: nil, provenance: .preset)
        )
        let other = AppDescriptor(
            packageName: try AndroidPackageName("com.other.app"),
            presentation: AppPresentation(displayName: "Other App", symbolName: nil, provenance: .generic)
        )
        let store = InMemoryAppSelectionStore(
            preferences: AppSelectionPreferences(
                favoritePackageNames: ["com.missing.app"],
                recentPackageNames: ["com.missing.app"]
            )
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel", transport: .usb
        )
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in AppModelAppCatalog(apps: [tile, other]) },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { store },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        await waitUntil { model.availableApps == [tile, other] }
        model.toggleFavorite(other)
        model.selectApp(tile)

        XCTAssertEqual(model.recentApps.map(\.id), [tile.id])
        XCTAssertEqual(model.favoriteApps.map(\.id), [other.id])
        XCTAssertTrue(model.isFavorite(other))
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Condition was not satisfied before timeout")
                return
            }
            await Task.yield()
        }
    }
}

private actor AppModelInstaller: ADBInstalling {
    let initialState: ADBInstallationState
    let installResult: Result<ADBInstallation, Error>
    private(set) var installCalls = 0

    init(
        initialState: ADBInstallationState,
        installResult: Result<ADBInstallation, Error> = .failure(ADBInstallerError.checksumMismatch)
    ) {
        self.initialState = initialState
        self.installResult = installResult
    }

    func state() -> ADBInstallationState {
        initialState
    }

    func install(acceptingLicense: Bool) throws -> ADBInstallation {
        installCalls += 1
        return try installResult.get()
    }

    func rollback() throws -> ADBInstallation {
        throw ADBInstallerError.noRollbackAvailable
    }
}

private actor AppModelDeviceService: DeviceServiceProtocol {
    let state: DeviceConnectionState

    init(state: DeviceConnectionState) {
        self.state = state
    }

    func refresh() async throws -> DeviceConnectionState { state }
}

private actor AppModelSequencedDeviceService: DeviceServiceProtocol {
    private var states: [DeviceConnectionState]

    init(states: [DeviceConnectionState]) {
        self.states = states
    }

    func refresh() async throws -> DeviceConnectionState {
        guard !states.isEmpty else { return .noDevice }
        return states.removeFirst()
    }
}

private actor AppModelAppCatalog: AppCatalogProtocol {
    let apps: [AppDescriptor]
    let processes: [ProcessDescriptor]

    init(apps: [AppDescriptor] = [], processes: [ProcessDescriptor] = []) {
        self.apps = apps
        self.processes = processes
    }

    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor] { apps }
    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor] { processes }
}

private struct AppModelLogSession: LogSessionProtocol {
    let emittedEvents: [LogEvent]
    let recordedEvents: [LogEvent]

    init(events: [LogEvent], recentEvents: [LogEvent] = []) {
        emittedEvents = events
        recordedEvents = recentEvents
    }

    func recentEvents(on device: DeviceDescriptor, pids: [Int32], limit: Int) async throws -> [LogEvent] {
        recordedEvents
    }

    func events(on device: DeviceDescriptor, pids: [Int32]) throws -> AsyncThrowingStream<LogEvent, Error> {
        AsyncThrowingStream { continuation in
            emittedEvents.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

private final class AppModelControlledLogSession: LogSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<LogEvent, Error>.Continuation?

    var hasSubscriber: Bool {
        lock.withLock { continuation != nil }
    }

    func events(on device: DeviceDescriptor, pids: [Int32]) throws -> AsyncThrowingStream<LogEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func emit(_ event: LogEvent) {
        _ = lock.withLock {
            continuation?.yield(event)
        }
    }
}

private final class InMemoryAppSelectionStore: AppSelectionStoreProtocol, @unchecked Sendable {
    private var value: AppSelectionPreferences

    init(preferences: AppSelectionPreferences = .empty) {
        value = preferences
    }

    var preferences: AppSelectionPreferences { value }

    @discardableResult
    func toggleFavorite(_ packageName: String) -> Bool {
        if let index = value.favoritePackageNames.firstIndex(of: packageName) {
            value.favoritePackageNames.remove(at: index)
            return false
        }
        value.favoritePackageNames.append(packageName)
        return true
    }

    func recordRecent(_ packageName: String) {
        value.recentPackageNames.removeAll { $0 == packageName }
        value.recentPackageNames.insert(packageName, at: 0)
        value.recentPackageNames = Array(value.recentPackageNames.prefix(6))
    }
}
