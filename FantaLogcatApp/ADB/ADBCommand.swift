import Foundation

enum ADBValidationError: Error, Equatable {
    case invalidEndpoint
    case invalidDeviceSerial
    case invalidPackageName
    case invalidPairingCode
    case invalidDeepLink
    case invalidActivityComponent
    case invalidInputText
    case invalidJSON
    case invalidAPK
    case invalidScreenshot
}

struct ADBDeepLink: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 4_096,
              !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: trimmed),
              components.scheme?.isEmpty == false else {
            throw ADBValidationError.invalidDeepLink
        }
        self.value = trimmed
    }
}

struct ADBInputText: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,_@:/+=-")
        guard !value.isEmpty,
              value.utf8.count <= 1_000,
              value.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw ADBValidationError.invalidInputText
        }
        self.value = value
    }

    var inputArgument: String {
        value.replacingOccurrences(of: " ", with: "%s")
    }
}

struct ADBJSONText: Sendable, Equatable {
    let value: String

    init(_ value: String) throws {
        guard let data = value.data(using: .utf8),
              data.count <= 10_000,
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any],
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: normalized, encoding: .utf8) else {
            throw ADBValidationError.invalidJSON
        }
        self.value = Self.asciiEscaped(text)
    }

    var base64: String {
        Data(value.utf8).base64EncodedString()
    }

    private static func asciiEscaped(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            guard !scalar.isASCII else { return String(scalar) }
            let codePoint = scalar.value
            if codePoint <= 0xFFFF {
                return String(format: "\\u%04X", codePoint)
            }
            let supplementary = codePoint - 0x1_0000
            let high = 0xD800 + (supplementary >> 10)
            let low = 0xDC00 + (supplementary & 0x3FF)
            return String(format: "\\u%04X\\u%04X", high, low)
        }
        .joined()
    }
}

struct APKInstallOptions: Sendable, Equatable {
    var replaceExisting = true
    var allowTestPackages = false
    var grantRuntimePermissions = false
    var allowDowngrade = false
}

enum AndroidDeviceProperty: String, Sendable, Equatable {
    case manufacturer = "ro.product.manufacturer"
    case model = "ro.product.model"
    case androidVersion = "ro.build.version.release"
    case sdk = "ro.build.version.sdk"
    case abi = "ro.product.cpu.abi"
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

struct AndroidPackageName: Sendable, Equatable, Codable {
    let value: String

    init(_ value: String) throws {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"#
        guard value.utf8.count <= 255,
              value.range(of: pattern, options: .regularExpression) != nil else {
            throw ADBValidationError.invalidPackageName
        }
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let packageName = try? AndroidPackageName(value) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid Android package name")
        }
        self = packageName
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
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
    case listThirdPartyPackagePaths(ADBDeviceSerial)
    case applicationLabel(ADBDeviceSerial, AndroidPackageName)
    case resolvePIDs(ADBDeviceSerial, AndroidPackageName)
    case pidOf(ADBDeviceSerial, AndroidPackageName)
    case startApplication(ADBDeviceSerial, AndroidPackageName)
    case stopApplication(ADBDeviceSerial, AndroidPackageName)
    case clearApplicationData(ADBDeviceSerial, AndroidPackageName)
    case installAPK(ADBDeviceSerial, URL, APKInstallOptions)
    case applicationDetails(ADBDeviceSerial, AndroidPackageName)
    case openDeepLink(ADBDeviceSerial, ADBDeepLink, AndroidPackageName?)
    case currentActivity(ADBDeviceSerial)
    case openActivity(ADBDeviceSerial, AndroidActivityComponent)
    case openActivityAsPackage(ADBDeviceSerial, AndroidActivityComponent)
    case inputText(ADBDeviceSerial, ADBInputText)
    case inputJSON(ADBDeviceSerial, ADBJSONText)
    case inputKeyEvent(ADBDeviceSerial, Int)
    case screenshot(ADBDeviceSerial)
    case deviceProperty(ADBDeviceSerial, AndroidDeviceProperty)
    case screenSize(ADBDeviceSerial)
    case screenDensity(ADBDeviceSerial)
    case batteryDetails(ADBDeviceSerial)
    case dataStorage(ADBDeviceSerial)
    case advertisingID(ADBDeviceSerial)
    case logcatSnapshotThreadtime(ADBDeviceSerial)
    case logcatThreadtime(ADBDeviceSerial)

    var arguments: [String] {
        return switch self {
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
        case .listThirdPartyPackagePaths(let serial):
            ["-s", serial.value, "shell", "pm", "list", "packages", "-3", "-f"]
        case .applicationLabel(let serial, let package):
            [
                "-s", serial.value, "shell",
                "dumpsys package \(package.value) | grep -m 1 '^[[:space:]]*application-label:'"
            ]
        case .resolvePIDs(let serial, _):
            ["-s", serial.value, "shell", "ps", "-A", "-o", "PID,NAME"]
        case .pidOf(let serial, let package):
            ["-s", serial.value, "shell", "pidof", package.value]
        case .startApplication(let serial, let package):
            ["-s", serial.value, "shell", "monkey", "-p", package.value,
             "-c", "android.intent.category.LAUNCHER", "1"]
        case .stopApplication(let serial, let package):
            ["-s", serial.value, "shell", "am", "force-stop", package.value]
        case .clearApplicationData(let serial, let package):
            ["-s", serial.value, "shell", "pm", "clear", package.value]
        case .installAPK(let serial, let fileURL, let options):
            ["-s", serial.value, "install"]
                + (options.replaceExisting ? ["-r"] : [])
                + (options.allowTestPackages ? ["-t"] : [])
                + (options.grantRuntimePermissions ? ["-g"] : [])
                + (options.allowDowngrade ? ["-d"] : [])
                + [fileURL.path]
        case .applicationDetails(let serial, let package):
            ["-s", serial.value, "shell", "dumpsys", "package", package.value]
        case .openDeepLink(let serial, let deepLink, let package):
            ["-s", serial.value, "shell", "am", "start", "-W", "-a",
             "android.intent.action.VIEW", "-d", Self.shellQuoted(deepLink.value)]
                + (package.map { ["-p", $0.value] } ?? [])
        case .currentActivity(let serial):
            ["-s", serial.value, "shell", "dumpsys", "activity", "activities"]
        case .openActivity(let serial, let component):
            ["-s", serial.value, "shell", "am", "start", "-W", "-n", component.value]
        case .openActivityAsPackage(let serial, let component):
            [
                "-s", serial.value, "shell", "run-as", component.packageName.value,
                "am", "start", "-W", "-n", component.value
            ]
        case .inputText(let serial, let text):
            ["-s", serial.value, "shell", "input", "text", text.inputArgument]
        case .inputJSON(let serial, let json):
            [
                "-s", serial.value, "shell",
                "payload=\(json.base64); decoded=$(printf %s \"$payload\" | base64 -d) || exit 1; input text \"$decoded\""
            ]
        case .inputKeyEvent(let serial, let keyCode):
            ["-s", serial.value, "shell", "input", "keyevent", String(keyCode)]
        case .screenshot(let serial):
            ["-s", serial.value, "exec-out", "screencap", "-p"]
        case .deviceProperty(let serial, let property):
            ["-s", serial.value, "shell", "getprop", property.rawValue]
        case .screenSize(let serial):
            ["-s", serial.value, "shell", "wm", "size"]
        case .screenDensity(let serial):
            ["-s", serial.value, "shell", "wm", "density"]
        case .batteryDetails(let serial):
            ["-s", serial.value, "shell", "dumpsys", "battery"]
        case .dataStorage(let serial):
            ["-s", serial.value, "shell", "df", "-h", "/data"]
        case .advertisingID(let serial):
            ["-s", serial.value, "shell", "settings", "get", "secure", "advertising_id"]
        case .logcatSnapshotThreadtime(let serial):
            // `logcat --pid` accepts a single PID, so a multi-process package
            // cannot be filtered on the device. Dump the full threadtime buffer
            // and filter by PID on the host instead.
            ["-s", serial.value, "logcat", "-d", "-v", "threadtime"]
        case .logcatThreadtime(let serial):
            ["-s", serial.value, "logcat", "-v", "threadtime"]
        }
    }

    var sensitiveValues: [String] {
        guard case .pair(_, let code) = self else { return [] }
        return [code.value]
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
