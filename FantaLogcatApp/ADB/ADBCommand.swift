import Foundation

enum ADBValidationError: Error, Equatable {
    case invalidEndpoint
    case invalidDeviceSerial
    case invalidPackageName
    case invalidPairingCode
}

struct ADBEndpoint: Sendable, Equatable {
    let host: String
    let port: UInt16

    init(host: String, port: Int) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty,
              host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(allowed.contains),
              (1...65_535).contains(port) else {
            throw ADBValidationError.invalidEndpoint
        }
        self.host = host
        self.port = UInt16(port)
    }

    var argument: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

struct ADBDeviceSerial: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw ADBValidationError.invalidDeviceSerial
        }
        self.value = value
    }
}

struct AndroidPackageName: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"#
        guard value.utf8.count <= 255,
              value.range(of: pattern, options: .regularExpression) != nil else {
            throw ADBValidationError.invalidPackageName
        }
        self.value = value
    }
}

struct ADBPairingCode: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        guard value.count == 6, value.allSatisfy(\.isNumber), value.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw ADBValidationError.invalidPairingCode
        }
        self.value = value
    }
}

enum ADBCommand: Sendable, Equatable {
    case version
    case devices(longFormat: Bool)
    case pair(ADBEndpoint, ADBPairingCode)
    case connect(ADBEndpoint)
    case disconnect(ADBEndpoint?)
    case listThirdPartyPackages(ADBDeviceSerial)
    case resolvePIDs(ADBDeviceSerial, AndroidPackageName)
    case startApplication(ADBDeviceSerial, AndroidPackageName)
    case logcatThreadtime(ADBDeviceSerial, pids: [Int32])

    var arguments: [String] {
        switch self {
        case .version:
            ["version"]
        case .devices(let longFormat):
            longFormat ? ["devices", "-l"] : ["devices"]
        case .pair(let endpoint, let code):
            ["pair", endpoint.argument, code.value]
        case .connect(let endpoint):
            ["connect", endpoint.argument]
        case .disconnect(let endpoint):
            endpoint.map { ["disconnect", $0.argument] } ?? ["disconnect"]
        case .listThirdPartyPackages(let serial):
            ["-s", serial.value, "shell", "pm", "list", "packages", "-3"]
        case .resolvePIDs(let serial, let package):
            ["-s", serial.value, "shell", "pidof", package.value]
        case .startApplication(let serial, let package):
            ["-s", serial.value, "shell", "monkey", "-p", package.value,
             "-c", "android.intent.category.LAUNCHER", "1"]
        case .logcatThreadtime(let serial, let pids):
            ["-s", serial.value, "logcat", "-v", "threadtime"]
                + pids.map { "--pid=\($0)" }
        }
    }
}
