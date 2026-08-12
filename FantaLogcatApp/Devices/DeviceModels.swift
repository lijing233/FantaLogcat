import Foundation

enum DeviceTransport: String, Sendable, Equatable {
    case usb
    case wireless
    case emulator
    case unknown
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
