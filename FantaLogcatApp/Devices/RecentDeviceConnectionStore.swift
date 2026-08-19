import Foundation

/// 一条最近设备连接记录：用于启动时自动进入与无线 TCP/IP 地址恢复。
struct RecentDeviceConnection: Codable, Equatable, Identifiable, Sendable {
    /// 当前阶段以 ADB serial 作为记录键；跨连接方式的稳定 ID（ro.serialno）去重属后续增强。
    var id: String { serial }

    var serial: String
    var displayName: String
    var transport: DeviceTransport
    /// 仅 wirelessTCPIP 保存连接地址（IP:端口）。
    var tcpIPAddress: String?
    var lastUsedAt: Date
    var autoRestoreEnabled: Bool

    init(
        serial: String,
        displayName: String,
        transport: DeviceTransport,
        tcpIPAddress: String? = nil,
        lastUsedAt: Date = Date(),
        autoRestoreEnabled: Bool = true
    ) {
        self.serial = serial
        self.displayName = displayName
        self.transport = transport
        self.tcpIPAddress = tcpIPAddress
        self.lastUsedAt = lastUsedAt
        self.autoRestoreEnabled = autoRestoreEnabled
    }
}

protocol RecentDeviceConnectionStore: Sendable {
    var records: [RecentDeviceConnection] { get }
    func upsert(_ record: RecentDeviceConnection)
    func remove(serial: String)
    func setAutoRestore(_ enabled: Bool, serial: String)
}

final class UserDefaultsRecentDeviceConnectionStore: RecentDeviceConnectionStore, @unchecked Sendable {
    static let storageKey = "io.github.fantalogcat.recent-device-connections.v1"
    static let maximumRecordCount = 6

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var records: [RecentDeviceConnection] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? decoder.decode([RecentDeviceConnection].self, from: data) else {
            return []
        }
        return decoded
    }

    func upsert(_ record: RecentDeviceConnection) {
        var updated = records.filter { $0.serial != record.serial }
        updated.insert(record, at: 0)
        updated.sort { $0.lastUsedAt > $1.lastUsedAt }
        save(Array(updated.prefix(Self.maximumRecordCount)))
    }

    func remove(serial: String) {
        save(records.filter { $0.serial != serial })
    }

    func setAutoRestore(_ enabled: Bool, serial: String) {
        var updated = records
        guard let index = updated.firstIndex(where: { $0.serial == serial }) else { return }
        updated[index].autoRestoreEnabled = enabled
        save(updated)
    }

    private func save(_ value: [RecentDeviceConnection]) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
