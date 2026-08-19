import Foundation
import XCTest
@testable import FantaLogcat

final class RecentDeviceConnectionStoreTests: XCTestCase {
    private let suiteName = "RecentDeviceConnectionStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> UserDefaultsRecentDeviceConnectionStore {
        UserDefaultsRecentDeviceConnectionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func testUpsertKeepsMostRecentFirstAndCapsAtSix() {
        let store = makeStore()
        for index in 0..<8 {
            store.upsert(RecentDeviceConnection(
                serial: "serial-\(index)",
                displayName: "Device \(index)",
                transport: .wirelessTCPIP,
                tcpIPAddress: "192.168.1.\(index):5555",
                lastUsedAt: Date(timeIntervalSince1970: Double(index))
            ))
        }

        XCTAssertEqual(store.records.count, 6)
        XCTAssertEqual(store.records.first?.serial, "serial-7")
    }

    func testUpsertReplacesExistingSerial() {
        let store = makeStore()
        store.upsert(RecentDeviceConnection(
            serial: "serial-a", displayName: "Old", transport: .usb, lastUsedAt: Date(timeIntervalSince1970: 1)
        ))
        store.upsert(RecentDeviceConnection(
            serial: "serial-a", displayName: "New", transport: .wirelessTCPIP,
            tcpIPAddress: "192.168.1.5:5555", lastUsedAt: Date(timeIntervalSince1970: 2)
        ))

        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.displayName, "New")
        XCTAssertEqual(store.records.first?.transport, .wirelessTCPIP)
    }

    func testRemoveAndSetAutoRestore() {
        let store = makeStore()
        store.upsert(RecentDeviceConnection(
            serial: "serial-a", displayName: "A", transport: .wirelessTCPIP,
            tcpIPAddress: "192.168.1.5:5555"
        ))

        store.setAutoRestore(false, serial: "serial-a")
        XCTAssertEqual(store.records.first?.autoRestoreEnabled, false)

        store.remove(serial: "serial-a")
        XCTAssertTrue(store.records.isEmpty)
    }
}
