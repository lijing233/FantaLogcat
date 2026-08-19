import Foundation

enum DeviceTransport: String, Codable, Sendable, Equatable {
    case usb
    case wirelessTLS
    case wirelessTCPIP
    case emulator
    case unknown

    /// 是否属于无线连接（用于"断开无线"等通用判断）。
    var isWireless: Bool {
        switch self {
        case .wirelessTLS, .wirelessTCPIP: true
        case .usb, .emulator, .unknown: false
        }
    }

    var symbolName: String {
        switch self {
        case .usb: "cable.connector"
        case .wirelessTLS, .wirelessTCPIP: "wifi"
        case .emulator: "desktopcomputer"
        case .unknown: "iphone"
        }
    }
}

struct DeviceDescriptor: Identifiable, Sendable, Equatable {
    let serial: ADBDeviceSerial
    let displayName: String
    let transport: DeviceTransport

    var id: String { serial.value }
}

enum DeviceConnectionState: Sendable, Equatable {
    case scanning
    case noDevice
    case authorizationRequired(DeviceDescriptor)
    case selectionRequired([DeviceDescriptor])
    case connected(DeviceDescriptor)
    case offline(DeviceDescriptor)
    case failed(String)
}
