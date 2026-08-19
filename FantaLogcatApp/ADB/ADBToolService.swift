import Foundation

enum ADBToolServiceError: Error, Equatable {
    case activityNotAccessible(String)
    case clipboardReadingUnavailable
}

struct APKInstallResult: Sendable, Equatable {
    let packageName: AndroidPackageName?
    let appInfo: AndroidAppInfo?
}

struct AndroidAppInfo: Sendable, Equatable {
    let packageName: AndroidPackageName
    let versionName: String
    let versionCode: String
    let minSDK: String
    let targetSDK: String
    let firstInstallTime: String
    let lastUpdateTime: String

    var formatted: String {
        [
            packageName.value,
            "Version: \(versionName) (\(versionCode))",
            "SDK: min \(minSDK), target \(targetSDK)",
            "First installed: \(firstInstallTime)",
            "Last updated: \(lastUpdateTime)"
        ].joined(separator: "\n")
    }
}

struct AndroidDeviceInfo: Sendable, Equatable {
    let serial: String
    let manufacturer: String
    let model: String
    let androidVersion: String
    let sdk: String
    let abi: String
    let screenSize: String
    let screenDensity: String
    let battery: String
    let dataStorage: String
    let advertisingID: String?

    var formatted: String {
        [
            "Serial: \(serial)",
            "Manufacturer: \(manufacturer)",
            "Model: \(model)",
            "Android: \(androidVersion) (SDK \(sdk))",
            "ABI: \(abi)",
            "Screen: \(screenSize) @ \(screenDensity)",
            "Battery: \(battery)",
            "Data storage: \(dataStorage)",
            "GAID: \(advertisingID ?? "Unavailable")"
        ].joined(separator: "\n")
    }
}

actor ADBToolService {
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    func installAPK(
        at fileURL: URL,
        on device: DeviceDescriptor,
        options: APKInstallOptions
    ) async throws -> APKInstallResult {
        guard fileURL.isFileURL,
              fileURL.pathExtension.lowercased() == "apk",
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ADBValidationError.invalidAPK
        }

        let before = try await installedPackagePaths(on: device)
        _ = try await adb.run(
            .installAPK(device.serial, fileURL.standardizedFileURL, options),
            timeout: .seconds(180)
        )
        let after = try await installedPackagePaths(on: device)
        let changedPackages = after.keys.filter { before[$0] != after[$0] }
        let package = changedPackages.count == 1
            ? try? AndroidPackageName(changedPackages[0])
            : nil
        let info: AndroidAppInfo? = if let package {
            try? await applicationInfo(for: package, on: device)
        } else {
            nil
        }
        return APKInstallResult(packageName: package, appInfo: info)
    }

    func applicationInfo(
        for package: AndroidPackageName,
        on device: DeviceDescriptor
    ) async throws -> AndroidAppInfo {
        let text = try await runText(
            .applicationDetails(device.serial, package),
            timeout: .seconds(20)
        )
        let versionLine = firstTrimmedLine(prefix: "versionCode=", in: text)
        return AndroidAppInfo(
            packageName: package,
            versionName: value(prefix: "versionName=", in: text) ?? "—",
            versionCode: token(after: "versionCode=", in: versionLine) ?? "—",
            minSDK: token(after: "minSdk=", in: versionLine) ?? "—",
            targetSDK: token(after: "targetSdk=", in: versionLine) ?? "—",
            firstInstallTime: value(prefix: "firstInstallTime=", in: text) ?? "—",
            lastUpdateTime: value(prefix: "lastUpdateTime=", in: text) ?? "—"
        )
    }

    func openApplication(_ package: AndroidPackageName, on device: DeviceDescriptor) async throws {
        _ = try await adb.run(.startApplication(device.serial, package), timeout: .seconds(15))
    }

    func openDeepLink(
        _ value: String,
        package: AndroidPackageName?,
        on device: DeviceDescriptor
    ) async throws -> String {
        let result = try await adb.run(
            .openDeepLink(device.serial, try ADBDeepLink(value), package),
            timeout: .seconds(15)
        )
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentActivity(on device: DeviceDescriptor) async throws -> AndroidActivityComponent {
        let output = try await runText(.currentActivity(device.serial), timeout: .seconds(15))
        let preferredMarkers = ["mResumedActivity:", "topResumedActivity=", "ResumedActivity:"]
        for marker in preferredMarkers {
            if let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains(marker) }),
               let component = Self.activityComponent(in: String(line)) {
                return component
            }
        }
        throw ADBValidationError.invalidActivityComponent
    }

    func openActivity(
        _ component: AndroidActivityComponent,
        on device: DeviceDescriptor
    ) async throws -> String {
        do {
            return try await openActivityText(.openActivity(device.serial, component))
        } catch let error as ADBError where Self.isActivityPermissionFailure(error) {
            do {
                return try await openActivityText(.openActivityAsPackage(device.serial, component))
            } catch {
                throw ADBToolServiceError.activityNotAccessible(Self.errorDetails(error))
            }
        }
    }

    func sendText(_ value: String, pressEnter: Bool, on device: DeviceDescriptor) async throws {
        let text = try ADBInputText(value)
        _ = try await adb.run(.inputText(device.serial, text), timeout: .seconds(15))
        if pressEnter {
            _ = try await adb.run(.inputKeyEvent(device.serial, 66), timeout: .seconds(10))
        }
    }

    func normalizedJSON(_ value: String) throws -> String {
        try ADBJSONText(value).value
    }

    func sendJSON(_ value: String, pressEnter: Bool, on device: DeviceDescriptor) async throws {
        let json = try ADBJSONText(value)
        _ = try await adb.run(.inputJSON(device.serial, json), timeout: .seconds(20))
        if pressEnter {
            _ = try await adb.run(.inputKeyEvent(device.serial, 66), timeout: .seconds(10))
        }
    }

    func screenshot(on device: DeviceDescriptor) async throws -> Data {
        let result = try await adb.run(.screenshot(device.serial), timeout: .seconds(20))
        guard result.stdout.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) else {
            throw ADBValidationError.invalidScreenshot
        }
        return result.stdout
    }

    /// 读取设备剪贴板文本。不同 Android/OEM 对 shell Clipboard API 的开放程度不同。
    func readClipboard(on device: DeviceDescriptor) async throws -> String {
        let commands: [ADBCommand] = [.clipboardGetText(device.serial), .clipboardGet(device.serial)]
        var lastCommandError: Error?
        var shellCommandUnsupported = false
        for command in commands {
            do {
                switch try await clipboardShellText(command) {
                case .text(let text):
                    return text
                case .unsupported:
                    shellCommandUnsupported = true
                case .diagnostic(let message):
                    lastCommandError = ADBError.commandFailed(exitCode: 0, stderrSummary: message)
                }
            } catch {
                lastCommandError = error
            }
        }

        // dumpsys 在部分旧系统上可读；它不保证包含主剪贴板内容，因此只在明确能解析时采用。
        do {
            let dump = try await runText(.clipboardDump(device.serial), timeout: .seconds(10))
            if let text = Self.clipboardText(inDump: dump) { return text }
        } catch {
            lastCommandError = error
        }

        if shellCommandUnsupported {
            // Binder transaction 编号会随 Android/OEM 变化，不能把猜测的编号当作通用读取方式。
            throw ADBToolServiceError.clipboardReadingUnavailable
        }
        if let lastCommandError { throw lastCommandError }
        throw ADBToolServiceError.clipboardReadingUnavailable
    }

    private enum ClipboardShellText {
        case text(String)
        case unsupported
        case diagnostic(String)
    }

    /// `cmd clipboard` 在部分厂商系统中会以 0 退出码将“不支持”写到 stderr。
    /// 只有 stdout 与 stderr 均为空时，才把它视为一个真实的空剪贴板。
    private func clipboardShellText(_ command: ADBCommand) async throws -> ClipboardShellText {
        let result = try await adb.run(command, timeout: .seconds(10))
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if diagnostic.localizedCaseInsensitiveContains("no shell command implementation") {
            return .unsupported
        }
        if !text.isEmpty { return .text(text) }
        if diagnostic.isEmpty { return .text("") }
        return .diagnostic(diagnostic)
    }

    private static func clipboardText(inDump dump: String) -> String? {
        let patterns = [#"(?:mPrimaryClip|primaryClip).*?(?:text|T:)[:=]([^}\n]+)"#, #"ClipData\s*\{[^\n]*T:([^}\n]+)"#]
        for pattern in patterns {
            guard let range = dump.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            let matched = String(dump[range])
            if let separator = matched.lastIndex(where: { $0 == ":" || $0 == "=" }) {
                let value = matched[matched.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
    }

    /// 从 `service call clipboard 2` 的 Parcel 十六进制输出中，提取剪贴板文本（UTF-16 解码）。
    /// Parcel 里还包含 MIME 类型等元数据，因此过滤掉 `text/plain` 这类 MIME 片段，返回最长的剩余文本。
    static func parseServiceCallClipboard(_ output: String) -> String? {
        var bytes: [UInt8] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let afterColon = line[line.index(after: colon)...]
            let hexPart = afterColon.prefix(while: { $0 != "'" })
            for word in hexPart.split(whereSeparator: \.isWhitespace) {
                guard word.count == 8, let value = UInt32(word, radix: 16) else { continue }
                bytes.append(UInt8(value & 0xFF))
                bytes.append(UInt8((value >> 8) & 0xFF))
                bytes.append(UInt8((value >> 16) & 0xFF))
                bytes.append(UInt8((value >> 24) & 0xFF))
            }
        }
        guard bytes.count >= 2 else { return nil }

        // 将字节流按小端 UTF-16 解码，并把连续的可见字符收集成若干“run”。
        // 代理对合并为单个 Character；NUL 与控制字符作为 run 边界。
        let units: [UInt16] = stride(from: 0, to: bytes.count - 1, by: 2).map {
            UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
        }
        var runs: [String] = []
        var current = ""
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 0 {
                if !current.isEmpty { runs.append(current) }
                current = ""
                index += 1
                continue
            }
            if (0xD800...0xDBFF).contains(unit), index + 1 < units.count {
                let next = units[index + 1]
                if (0xDC00...0xDFFF).contains(next) {
                    let combined = (UInt32(unit - 0xD800) << 10)
                        + UInt32(next - 0xDC00) + 0x1_0000
                    if let scalar = UnicodeScalar(combined) {
                        current.append(Character(scalar))
                    }
                    index += 2
                    continue
                }
            }
            if (0xD800...0xDFFF).contains(unit) || unit < 0x20 {
                if !current.isEmpty { runs.append(current) }
                current = ""
            } else if let scalar = UnicodeScalar(unit) {
                current.append(Character(scalar))
            }
            index += 1
        }
        if !current.isEmpty { runs.append(current) }

        let mimePattern = #"^[a-z]+/[a-z0-9.+_-]+$"#
        let candidates = runs.filter { run in
            run.range(of: mimePattern, options: .regularExpression) == nil
        }
        return candidates.max(by: { $0.count < $1.count })
    }

    func restart(_ package: AndroidPackageName, on device: DeviceDescriptor) async throws {
        _ = try await adb.run(.stopApplication(device.serial, package), timeout: .seconds(10))
        _ = try await adb.run(.startApplication(device.serial, package), timeout: .seconds(15))
    }

    func closeApplication(_ package: AndroidPackageName, on device: DeviceDescriptor) async throws {
        _ = try await adb.run(.stopApplication(device.serial, package), timeout: .seconds(10))
    }

    func clearData(for package: AndroidPackageName, on device: DeviceDescriptor) async throws {
        _ = try await adb.run(.clearApplicationData(device.serial, package), timeout: .seconds(20))
    }

    func deviceInfo(on device: DeviceDescriptor) async throws -> AndroidDeviceInfo {
        async let manufacturer = property(.manufacturer, on: device)
        async let model = property(.model, on: device)
        async let androidVersion = property(.androidVersion, on: device)
        async let sdk = property(.sdk, on: device)
        async let abi = property(.abi, on: device)
        async let screenSize = runText(.screenSize(device.serial), timeout: .seconds(10))
        async let screenDensity = runText(.screenDensity(device.serial), timeout: .seconds(10))
        async let batteryDetails = runText(.batteryDetails(device.serial), timeout: .seconds(10))
        async let storageDetails = runText(.dataStorage(device.serial), timeout: .seconds(10))
        async let advertisingID = bestEffortAdvertisingID(on: device)
        return try await AndroidDeviceInfo(
            serial: device.serial.value,
            manufacturer: manufacturer,
            model: model,
            androidVersion: androidVersion,
            sdk: sdk,
            abi: abi,
            screenSize: screenSize.replacingOccurrences(of: "Physical size: ", with: ""),
            screenDensity: screenDensity.replacingOccurrences(of: "Physical density: ", with: ""),
            battery: Self.parseBattery(batteryDetails),
            dataStorage: Self.parseStorage(storageDetails),
            advertisingID: advertisingID
        )
    }

    private func installedPackagePaths(on device: DeviceDescriptor) async throws -> [String: String] {
        let text = try await runText(
            .listThirdPartyPackagePaths(device.serial),
            timeout: .seconds(20)
        )
        return text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let value = String(line)
            guard value.hasPrefix("package:"),
                  let separator = value.lastIndex(of: "=") else { return }
            let path = String(value[value.index(value.startIndex, offsetBy: 8)..<separator])
            let package = String(value[value.index(after: separator)...])
            if !path.isEmpty, !package.isEmpty { result[package] = path }
        }
    }

    private func property(
        _ property: AndroidDeviceProperty,
        on device: DeviceDescriptor
    ) async throws -> String {
        try await runText(.deviceProperty(device.serial, property), timeout: .seconds(10))
    }

    private func bestEffortAdvertisingID(on device: DeviceDescriptor) async -> String? {
        guard let raw = try? await runText(
            .advertisingID(device.serial),
            timeout: .seconds(10)
        ) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.lowercased() != "null",
              value != "00000000-0000-0000-0000-000000000000" else { return nil }
        return value
    }

    private func runText(_ command: ADBCommand, timeout: Duration) async throws -> String {
        let result = try await adb.run(command, timeout: timeout)
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func value(prefix: String, in text: String) -> String? {
        firstTrimmedLine(prefix: prefix, in: text).flatMap { line in
            let result = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return result.isEmpty ? nil : result
        }
    }

    private func firstTrimmedLine(prefix: String, in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix(prefix) })
    }

    private func token(after prefix: String, in line: String?) -> String? {
        guard let line, let range = line.range(of: prefix) else { return nil }
        return line[range.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func parseBattery(_ text: String) -> String {
        let fields = colonFields(text)
        let level = fields["level"].map { "\($0)%" } ?? "—"
        let temperature = fields["temperature"].flatMap(Double.init).map {
            String(format: "%.1f°C", $0 / 10)
        } ?? "—"
        let state = switch fields["status"] {
        case "2": "charging"
        case "3": "discharging"
        case "4": "not charging"
        case "5": "full"
        default: "unknown"
        }
        return "\(level), \(temperature), \(state)"
    }

    private static func parseStorage(_ text: String) -> String {
        guard let line = text.split(whereSeparator: \.isNewline).last else { return "—" }
        let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard columns.count >= 5 else { return String(line) }
        return "\(columns[2]) / \(columns[1]) (\(columns[4]))"
    }

    private static func colonFields(_ text: String) -> [String: String] {
        text.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(of: ":") else { return }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
    }

    private static func activityComponent(in line: String) -> AndroidActivityComponent? {
        let pattern = #"[A-Za-z_][A-Za-z0-9_.]*/\.?[A-Za-z_$][A-Za-z0-9_.$]*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
        return try? AndroidActivityComponent(String(line[range]))
    }

    private func openActivityText(_ command: ADBCommand) async throws -> String {
        let result = try await adb.run(command, timeout: .seconds(15))
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isActivityPermissionFailure(_ error: ADBError) -> Bool {
        guard case .commandFailed(_, let summary) = error else { return false }
        let value = summary.lowercased()
        return value.contains("permission denial")
            || value.contains("security exception")
            || value.contains("not exported")
    }

    private static func errorDetails(_ error: Error) -> String {
        guard let adbError = error as? ADBError,
              case .commandFailed(_, let summary) = adbError,
              !summary.isEmpty else { return String(describing: error) }
        return summary
    }
}
