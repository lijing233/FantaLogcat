import Foundation

protocol DeviceServiceProtocol: Sendable {
    func refresh() async throws -> DeviceConnectionState
}

actor DeviceService: DeviceServiceProtocol {
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    func refresh() async throws -> DeviceConnectionState {
        let result = try await adb.run(.devices(longFormat: true), timeout: .seconds(5))
        let records = Self.parse(String(decoding: result.stdout, as: UTF8.self))
        let online = records.filter { $0.status == "device" }.map(\.descriptor).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        if online.count == 1, let device = online.first { return .connected(device) }
        if online.count > 1 { return .selectionRequired(online) }
        if let unauthorized = records.first(where: { $0.status == "unauthorized" }) {
            return .authorizationRequired(unauthorized.descriptor)
        }
        if let offline = records.first(where: { $0.status == "offline" }) {
            return .offline(offline.descriptor)
        }
        return .noDevice
    }

    private struct Record: Sendable {
        let descriptor: DeviceDescriptor
        let status: String
    }

    private static func parse(_ output: String) -> [Record] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: \ .isWhitespace)
            guard tokens.count >= 2,
                  tokens[0] != "List",
                  let serial = try? ADBDeviceSerial(String(tokens[0])) else {
                return nil
            }
            let status = String(tokens[1])
            let details = Dictionary(uniqueKeysWithValues: tokens.dropFirst(2).compactMap { token in
                let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
            let displayName = details["model"]?.replacingOccurrences(of: "_", with: " ")
                ?? (serial.value.hasPrefix("emulator-") ? "Android Emulator" : "Android device")
            let transport: DeviceTransport
            if serial.value.hasPrefix("emulator-") { transport = .emulator }
            else if serial.value.contains(":") { transport = .wireless }
            else if details["usb"] != nil { transport = .usb }
            else { transport = .unknown }
            return Record(
                descriptor: DeviceDescriptor(serial: serial, displayName: displayName, transport: transport),
                status: status
            )
        }
    }
}
