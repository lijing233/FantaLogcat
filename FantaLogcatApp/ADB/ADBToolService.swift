import Foundation

enum ADBToolServiceError: Error, Equatable {
    case activityNotAccessible(String)
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
