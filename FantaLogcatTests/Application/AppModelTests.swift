import Foundation
import XCTest
@testable import FantaLogcat

@MainActor
final class AppModelTests: XCTestCase {
    func testClearLogFiltersRestoresAllLevelsAndEmptyKeyword() {
        let store = InMemoryAppSettingsStore(settings: .init(language: .chinese, capture: .init()))
        let model = AppModel(environment: .test(), settingsStore: store)
        model.setLogLevels([.error])
        model.setLogKeyword("Unity")

        model.clearLogFilters()

        XCTAssertEqual(model.logFilter, LogFilter())
    }

    func testSaveSettingsAppliesAllFieldsAndPersistsOnce() throws {
        let store = InMemoryAppSettingsStore(settings: .init(language: .chinese, capture: .init()))
        let model = AppModel(environment: .test(), settingsStore: store)
        let draft = AppSettings(language: .english, appearance: .dark, defaultDeviceDestination: .toolbox, capture: .init(historyLines: 100, maxEvents: 5_000, maxTextBytes: 16 * 1_024 * 1_024, redactExportsByDefault: false))

        try model.saveSettings(draft)

        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.appearance, .dark)
        XCTAssertEqual(model.settingsDraft.defaultDeviceDestination, .toolbox)
        XCTAssertEqual(model.captureSettings, draft.capture)
        XCTAssertEqual(store.savedValues, [draft])
    }

    func testAppearancePreviewAppliesImmediatelyAndCanBeReverted() {
        let store = InMemoryAppSettingsStore(
            settings: .init(language: .chinese, appearance: .system, capture: .init())
        )
        let model = AppModel(environment: .test(), settingsStore: store)

        XCTAssertEqual(model.effectiveAppearance, .system)
        model.previewAppearance(.dark)
        XCTAssertEqual(model.effectiveAppearance, .dark)
        XCTAssertEqual(model.settingsDraft.appearance, .system)

        model.endAppearancePreview()
        XCTAssertEqual(model.effectiveAppearance, .system)
    }

    func testFailedSettingsPersistenceDoesNotPublishPartialState() {
        let original = AppSettings(language: .chinese, capture: .init(historyLines: 100))
        let store = InMemoryAppSettingsStore(settings: original, saveError: TestSettingsStoreError.failed)
        let model = AppModel(environment: .test(), settingsStore: store)
        let draft = AppSettings(
            language: .english,
            appearance: .light,
            capture: .init(historyLines: 999, maxEvents: 1, maxTextBytes: 1, redactExportsByDefault: false)
        )

        XCTAssertThrowsError(try model.saveSettings(draft))

        XCTAssertEqual(model.settingsDraft, original)
        XCTAssertEqual(store.settings, original)
        XCTAssertEqual(store.savedValues, [])
    }

    func testSaveSettingsPublishesOneNormalizedSettingsValue() throws {
        let store = InMemoryAppSettingsStore(settings: .init(language: .chinese, capture: .init()))
        let model = AppModel(environment: .test(), settingsStore: store)
        let draft = AppSettings(
            language: .english,
            appearance: .light,
            capture: .init(historyLines: 999, maxEvents: 1, maxTextBytes: 1, redactExportsByDefault: false)
        )

        try model.saveSettings(draft)

        XCTAssertEqual(model.settingsDraft.language, .english)
        XCTAssertEqual(model.settingsDraft.appearance, .light)
        XCTAssertEqual(model.settingsDraft.capture.historyLines, 500)
        XCTAssertEqual(model.settingsDraft.capture.maxEvents, 1_000)
        XCTAssertEqual(model.settingsDraft.capture.maxTextBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(store.savedValues, [model.settingsDraft])
    }

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
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: AppModelDeviceService(state: .connected(device))
            ),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            )
        )

        await model.prepareADB()
        await model.refreshDevices()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testSingleDeviceCanOpenToolboxByDefault() async {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try! ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let settingsStore = InMemoryAppSettingsStore(settings: .init(
            language: .chinese,
            defaultDeviceDestination: .toolbox,
            capture: .init()
        ))
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: AppModelDeviceService(state: .connected(device))
            ),
            settingsStore: settingsStore
        )

        await model.prepareADB()
        await model.refreshDevices()

        XCTAssertEqual(model.phase, .toolbox)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testToolboxUsesNormalNavigationPhaseAndReturnsToAppSelection() async {
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
        model.openToolbox()
        XCTAssertEqual(model.phase, .toolbox)

        model.closeToolbox()
        XCTAssertEqual(model.phase, .selectingApp)
    }

    func testSingleTransientDisconnectDoesNotReturnToDeviceSelection() async throws {
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
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: service
            ),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            )
        )

        await model.prepareADB()
        await model.refreshDevices()
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)

        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testRepeatedDisconnectsReturnToDeviceSelectionAndRecoverAutomatically() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let service = AppModelSequencedDeviceService(states: [.connected(device), .noDevice, .noDevice, .connected(device)])
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: service
            ),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            )
        )

        await model.prepareADB()
        await model.refreshDevices()
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)

        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingDevice)
        XCTAssertEqual(model.deviceConnection, .noDevice)

        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, device)
    }

    func testSelectionRequiredKeepsSessionWhenSelectedDeviceStillPresent() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let deviceA = DeviceDescriptor(
            serial: try ADBDeviceSerial("AAAA"),
            displayName: "Pixel A",
            transport: .usb
        )
        let deviceB = DeviceDescriptor(
            serial: try ADBDeviceSerial("BBBB"),
            displayName: "Pixel B",
            transport: .usb
        )
        let service = AppModelSequencedDeviceService(states: [
            .connected(deviceA),
            .selectionRequired([deviceA, deviceB]),
            .selectionRequired([deviceA, deviceB])
        ])
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: service
            ),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            )
        )

        await model.prepareADB()
        await model.refreshDevices()
        await model.monitorDeviceConnection()
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)
        XCTAssertEqual(model.selectedDevice, deviceA)
        XCTAssertEqual(model.deviceConnection, .connected(deviceA))
    }

    func testSwitchToDeviceMigratesLogSessionPreservingFilterAndPause() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let usbDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let wirelessDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("192.168.1.5:5555"),
            displayName: "Pixel 8",
            transport: .wirelessTCPIP
        )
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let logSession = AppModelTrackingLogSession()
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(usbDevice)) },
            makeAppCatalog: { _ in AppModelAppCatalog(apps: [app], processes: [ProcessDescriptor(pid: 42, name: "com.example.game")]) },
            makeLogSession: { _ in logSession },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.setLogKeyword("Unity")
        model.selectApp(app)
        await waitUntil { logSession.streamPIDs.count >= 1 }
        model.pauseLogPresentation()

        model.switchToDevice(wirelessDevice)

        XCTAssertEqual(model.phase, .viewingLogs)
        XCTAssertEqual(model.selectedDevice, wirelessDevice)
        XCTAssertEqual(model.logFilter.keyword, "Unity")
        XCTAssertTrue(model.isLogPresentationPaused)
        await waitUntil { logSession.streamPIDs.count >= 2 }
        XCTAssertEqual(logSession.streamPIDs.count, 2)
    }

    func testDisconnectWirelessDeviceDisconnectsBySerial() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        // TLS 无线设备序列号为 mDNS 实例名（非 IP:端口），断开必须按序列号原样传递。
        let wirelessDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("adb-14141FDF600081-TnSdi9"),
            displayName: "Pixel 8",
            transport: .wirelessTLS
        )
        let wireless = AppModelRecordingWirelessService()
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(wirelessDevice)) },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeWirelessService: { _ in wireless },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        await model.disconnectWirelessDevice()

        let addresses = await wireless.disconnectedAddresses
        XCTAssertEqual(addresses, ["adb-14141FDF600081-TnSdi9"])
    }

    func testAdoptWirelessDeviceSelectsNewlyPairedDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let existingDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Existing",
            transport: .usb
        )
        let newDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("adb-14141FDF600081-TnSdi9"),
            displayName: "Pixel 8",
            transport: .wirelessTLS
        )
        let service = AppModelSequencedDeviceService(states: [
            .connected(existingDevice),
            .connected(existingDevice),
            .selectionRequired([existingDevice, newDevice])
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        await model.snapshotKnownDeviceSerials()

        let adopted = await model.adoptWirelessDevice()

        XCTAssertTrue(adopted)
        XCTAssertEqual(model.selectedDevice, newDevice)
    }

    func testAdoptWirelessDeviceReturnsFalseWhenNoNewDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let existingDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Existing",
            transport: .usb
        )
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(existingDevice)) },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        await model.snapshotKnownDeviceSerials()

        let adopted = await model.adoptWirelessDevice()

        XCTAssertFalse(adopted)
        XCTAssertEqual(model.selectedDevice, existingDevice)
    }

    func testSwitchUSBToWirelessSwitchesToNewWirelessDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let usbDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let wirelessDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("192.168.1.5:5555"),
            displayName: "Pixel 8",
            transport: .wirelessTCPIP
        )
        let service = AppModelSequencedDeviceService(states: [
            .connected(usbDevice),
            .connected(usbDevice),
            .connected(wirelessDevice)
        ])
        let wireless = AppModelRecordingWirelessService(wifiIP: "192.168.1.5")
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeWirelessService: { _ in wireless },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()

        let switched = try await model.switchUSBToWireless()

        XCTAssertTrue(switched)
        XCTAssertEqual(model.selectedDevice, wirelessDevice)
        let ports = await wireless.recordedTCPIPPorts
        let connects = await wireless.recordedConnects
        XCTAssertEqual(ports, [5_555])
        XCTAssertEqual(connects, [try ADBEndpoint(host: "192.168.1.5", port: 5_555)])
    }

    func testSwitchUSBToWirelessThrowsWhenWifiIPUnavailable() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let usbDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let wireless = AppModelRecordingWirelessService(wifiIP: nil)
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(usbDevice)) },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeWirelessService: { _ in wireless },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()

        do {
            _ = try await model.switchUSBToWireless()
            XCTFail("Expected wifiIPUnavailable")
        } catch let error as WirelessDebugError {
            XCTAssertEqual(error, .wifiIPUnavailable)
        }
    }

    func testSwitchProtectionSuppressesTransientDisconnects() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let usbDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let service = AppModelSequencedDeviceService(states: [
            .connected(usbDevice),
            .noDevice, .noDevice, .noDevice, .noDevice
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ), settingsStore: InMemoryAppSettingsStore(
            settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.beginSwitchProtection()

        await model.monitorDeviceConnection()
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingApp)

        model.endSwitchProtection()
        await model.monitorDeviceConnection()
        XCTAssertEqual(model.phase, .selectingApp)
        await model.monitorDeviceConnection()

        XCTAssertEqual(model.phase, .selectingDevice)
    }

    func testAdoptDeviceBySerialSelectsMatchingDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let usbDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("ABC123"),
            displayName: "Pixel 8",
            transport: .usb
        )
        let wirelessDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("192.168.1.5:5555"),
            displayName: "Pixel 8",
            transport: .wirelessTCPIP
        )
        let service = AppModelSequencedDeviceService(states: [
            .connected(usbDevice),
            .selectionRequired([usbDevice, wirelessDevice])
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ), settingsStore: InMemoryAppSettingsStore(
            settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
        ))

        await model.prepareADB()
        await model.refreshDevices()

        let adopted = await model.adoptDevice(withSerial: "192.168.1.5:5555")

        XCTAssertTrue(adopted)
        XCTAssertEqual(model.selectedDevice, wirelessDevice)
    }

    func testStartupRecoversSavedTCPIPDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let wirelessDevice = DeviceDescriptor(
            serial: try ADBDeviceSerial("192.168.1.5:5555"),
            displayName: "Pixel 8",
            transport: .wirelessTCPIP
        )
        let service = AppModelSequencedDeviceService(states: [.noDevice, .connected(wirelessDevice)])
        let recentStore = InMemoryRecentDeviceConnectionStore(records: [
            RecentDeviceConnection(
                serial: "192.168.1.5:5555",
                displayName: "Pixel 8",
                transport: .wirelessTCPIP,
                tcpIPAddress: "192.168.1.5:5555"
            )
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeWirelessService: { _ in AppModelRecordingWirelessService(wifiIP: "192.168.1.5") },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ), settingsStore: InMemoryAppSettingsStore(
            settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
        ), recentDeviceStore: recentStore)

        await model.startup()
        await waitUntil(timeout: .seconds(2)) { model.selectedDevice == wirelessDevice }

        XCTAssertEqual(model.selectedDevice, wirelessDevice)
        XCTAssertEqual(model.phase, .selectingApp)
    }

    func testStartupFallsBackWhenSavedTCPIPUnavailable() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let service = AppModelSequencedDeviceService(states: [.noDevice, .noDevice])
        let recentStore = InMemoryRecentDeviceConnectionStore(records: [
            RecentDeviceConnection(
                serial: "192.168.1.5:5555",
                displayName: "Pixel 8",
                transport: .wirelessTCPIP,
                tcpIPAddress: "192.168.1.5:5555"
            )
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeWirelessService: { _ in AppModelRecordingWirelessService(wifiIP: "192.168.1.5") },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ), settingsStore: InMemoryAppSettingsStore(
            settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
        ), recentDeviceStore: recentStore)

        await model.startup()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.phase, .selectingDevice)
        XCTAssertNil(model.selectedDevice)
    }

    func testStartupSelectsLastUsedDeviceAmongMultiple() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let deviceA = DeviceDescriptor(
            serial: try ADBDeviceSerial("AAAA"),
            displayName: "Pixel A",
            transport: .usb
        )
        let deviceB = DeviceDescriptor(
            serial: try ADBDeviceSerial("BBBB"),
            displayName: "Pixel B",
            transport: .usb
        )
        let service = AppModelSequencedDeviceService(states: [
            .selectionRequired([deviceA, deviceB])
        ])
        let recentStore = InMemoryRecentDeviceConnectionStore(records: [
            RecentDeviceConnection(serial: "BBBB", displayName: "Pixel B", transport: .usb, lastUsedAt: Date(timeIntervalSince1970: 2)),
            RecentDeviceConnection(serial: "AAAA", displayName: "Pixel A", transport: .usb, lastUsedAt: Date(timeIntervalSince1970: 1))
        ])
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in service },
            makeAppCatalog: { _ in AppModelAppCatalog() },
            makeLogSession: { _ in AppModelLogSession(events: []) },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ), settingsStore: InMemoryAppSettingsStore(
            settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
        ), recentDeviceStore: recentStore)

        await model.startup()

        XCTAssertEqual(model.selectedDevice, deviceB)
    }

    func testRecordingRecentDevicePreservesAutoRestoreSetting() throws {
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("AAAA"),
            displayName: "Pixel A",
            transport: .usb
        )
        let recentStore = InMemoryRecentDeviceConnectionStore(records: [
            RecentDeviceConnection(
                serial: "AAAA",
                displayName: "Pixel A",
                transport: .usb,
                autoRestoreEnabled: false
            )
        ])
        let model = AppModel(
            environment: .test(),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            ),
            recentDeviceStore: recentStore
        )

        model.switchToDevice(device)

        XCTAssertEqual(recentStore.records.first?.serial, "AAAA")
        XCTAssertEqual(recentStore.records.first?.autoRestoreEnabled, false)
    }

    func testMonitorPollDoesNotReRecordRecentDevice() async throws {
        let installation = ADBInstallation(
            version: "37.0.0",
            executableURL: URL(fileURLWithPath: "/managed/adb")
        )
        let device = DeviceDescriptor(
            serial: try ADBDeviceSerial("AAAA"),
            displayName: "Pixel A",
            transport: .usb
        )
        let service = AppModelDeviceService(state: .connected(device))
        let recentStore = InMemoryRecentDeviceConnectionStore()
        let model = AppModel(
            environment: .test(
                installer: AppModelInstaller(initialState: .ready(installation)),
                deviceService: service
            ),
            settingsStore: InMemoryAppSettingsStore(
                settings: .init(language: .chinese, defaultDeviceDestination: .logs, capture: .init())
            ),
            recentDeviceStore: recentStore
        )

        await model.prepareADB()
        model.selectDevice(device)
        let recordedAt = recentStore.records.first?.lastUsedAt
        XCTAssertNotNil(recordedAt)

        await model.monitorDeviceConnection()

        XCTAssertEqual(recentStore.records.first?.lastUsedAt, recordedAt)
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

    func testPIDChangeRestartsCaptureAndLoadsHistoryOnlyForNewPID() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let device = DeviceDescriptor(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb)
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let catalog = AppModelSequencedAppCatalog(
            apps: [app],
            processResponses: [
                [ProcessDescriptor(pid: 42, name: "com.example.game")],
                [ProcessDescriptor(pid: 84, name: "com.example.game")]
            ]
        )
        let session = AppModelTrackingLogSession()
        let model = AppModel(environment: AppEnvironment(
            makeADBInstaller: { AppModelInstaller(initialState: .ready(installation)) },
            makeDeviceService: { _ in AppModelDeviceService(state: .connected(device)) },
            makeAppCatalog: { _ in catalog },
            makeLogSession: { _ in session },
            makeAppSelectionStore: { InMemoryAppSelectionStore() },
            adbLicenseURL: URL(string: "https://example.com/terms")!
        ))

        await model.prepareADB()
        await model.refreshDevices()
        model.selectApp(app)
        await waitUntil(timeout: .seconds(4)) { session.streamPIDs.count >= 2 }

        XCTAssertEqual(Array(session.streamPIDs.prefix(2)), [[42], [84]])
        XCTAssertEqual(Array(session.historyPIDs.prefix(2)), [[42], [84]])
        model.returnToAppSelection()
    }

    func testLogStreamFailureRetriesCapture() async throws {
        let installation = ADBInstallation(version: "37.0.0", executableURL: URL(fileURLWithPath: "/managed/adb"))
        let device = DeviceDescriptor(serial: try ADBDeviceSerial("ABC123"), displayName: "Pixel 8", transport: .usb)
        let app = AppDescriptor(
            packageName: try AndroidPackageName("com.example.game"),
            presentation: AppPresentation(displayName: "Example", symbolName: nil, provenance: .generic)
        )
        let session = AppModelRetryingLogSession()
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
        await waitUntil(timeout: .seconds(3)) { session.attempts >= 2 }

        XCTAssertGreaterThanOrEqual(session.attempts, 2)
        XCTAssertNil(model.logStreamError)
        model.returnToAppSelection()
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
        XCTAssertEqual(model.filteredLogEvents.map(\.id), [2, 3])
    }

    func testEvictionRebuildsFilteredEventsWithoutStaleMatches() async throws {
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
                message: id == 3 ? "drop" : "keep",
                rawText: id == 3 ? "drop" : "keep",
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
            cacheLimits: .init(maxEvents: 2, maxTextBytes: 1_000_000)
        )

        await model.prepareADB()
        await model.refreshDevices()
        model.setLogKeyword("keep")
        model.selectApp(app)
        await waitUntil { model.logEvents.map(\.id) == [2, 3] }

        XCTAssertEqual(model.logEvents.map(\.id), [2, 3])
        XCTAssertEqual(model.filteredLogEvents.map(\.id), [2])
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

private actor AppModelSequencedAppCatalog: AppCatalogProtocol {
    let apps: [AppDescriptor]
    private var processResponses: [[ProcessDescriptor]]

    init(apps: [AppDescriptor], processResponses: [[ProcessDescriptor]]) {
        self.apps = apps
        self.processResponses = processResponses
    }

    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor] { apps }

    func resolveProcesses(
        packageName: AndroidPackageName,
        on device: DeviceDescriptor
    ) async throws -> [ProcessDescriptor] {
        guard processResponses.count > 1 else { return processResponses.first ?? [] }
        return processResponses.removeFirst()
    }
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

private final class AppModelTrackingLogSession: LogSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStreamPIDs: [[Int32]] = []
    private var recordedHistoryPIDs: [[Int32]] = []

    var streamPIDs: [[Int32]] { lock.withLock { recordedStreamPIDs } }
    var historyPIDs: [[Int32]] { lock.withLock { recordedHistoryPIDs } }

    func recentEvents(on device: DeviceDescriptor, pids: [Int32], limit: Int) async throws -> [LogEvent] {
        lock.withLock { recordedHistoryPIDs.append(pids) }
        return []
    }

    func events(on device: DeviceDescriptor, pids: [Int32]) throws -> AsyncThrowingStream<LogEvent, Error> {
        lock.withLock { recordedStreamPIDs.append(pids) }
        return AsyncThrowingStream { _ in }
    }
}

private final class AppModelRetryingLogSession: LogSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var attemptCount = 0

    var attempts: Int { lock.withLock { attemptCount } }

    func events(on device: DeviceDescriptor, pids: [Int32]) throws -> AsyncThrowingStream<LogEvent, Error> {
        let attempt = lock.withLock {
            attemptCount += 1
            return attemptCount
        }
        return AsyncThrowingStream { continuation in
            if attempt == 1 {
                continuation.finish(throwing: AppModelTestError.streamFailed)
            }
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

private final class InMemoryAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private(set) var settings: AppSettings
    private(set) var savedValues: [AppSettings] = []
    private let saveError: Error?

    init(settings: AppSettings, saveError: Error? = nil) {
        self.settings = settings
        self.saveError = saveError
    }

    func save(_ settings: AppSettings) throws {
        if let saveError { throw saveError }
        self.settings = settings
        savedValues.append(settings)
    }
}

private enum TestSettingsStoreError: Error {
    case failed
}

private actor AppModelRecordingWirelessService: WirelessDebugServiceProtocol {
    private let wifiIP: String?
    private var addresses: [String?] = []
    private var ports: [Int] = []
    private var endpoints: [ADBEndpoint] = []

    init(wifiIP: String? = nil) {
        self.wifiIP = wifiIP
    }

    var disconnectedAddresses: [String?] { addresses }
    var recordedTCPIPPorts: [Int] { ports }
    var recordedConnects: [ADBEndpoint] { endpoints }

    func mDNSAvailable() async -> Bool { false }
    func discoverPairingEndpoint(serviceName: String) async throws -> ADBEndpoint? { nil }
    func pair(endpoint: ADBEndpoint, secret: String) async throws {}
    func connect(endpoint: ADBEndpoint) async throws { endpoints.append(endpoint) }
    func enableTCPIP(serial: ADBDeviceSerial, port: Int) async throws { ports.append(port) }
    func restoreUSB(serial: ADBDeviceSerial) async throws {}
    func disconnect(address: String?) async throws { addresses.append(address) }
    func restartServer() async throws {}
    func wifiIPAddress(serial: ADBDeviceSerial) async throws -> String? { wifiIP }
}

private final class InMemoryRecentDeviceConnectionStore: RecentDeviceConnectionStore, @unchecked Sendable {
    private var value: [RecentDeviceConnection]

    init(records: [RecentDeviceConnection] = []) {
        value = records
    }

    var records: [RecentDeviceConnection] { value }

    func upsert(_ record: RecentDeviceConnection) {
        value.removeAll { $0.serial == record.serial }
        value.insert(record, at: 0)
        value.sort { $0.lastUsedAt > $1.lastUsedAt }
        value = Array(value.prefix(6))
    }

    func remove(serial: String) {
        value.removeAll { $0.serial == serial }
    }

    func setAutoRestore(_ enabled: Bool, serial: String) {
        guard let index = value.firstIndex(where: { $0.serial == serial }) else { return }
        value[index].autoRestoreEnabled = enabled
    }
}

private enum AppModelTestError: Error {
    case streamFailed
}
