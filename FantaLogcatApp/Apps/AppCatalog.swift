import Foundation

protocol AppCatalogProtocol: Sendable {
    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor]
    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor]
}

actor AppCatalog: AppCatalogProtocol {
    private let adb: any ADBRuntimeProtocol
    private let presets: [AppPreset]
    private var applicationLabelCache: [String: String] = [:]

    init(adb: any ADBRuntimeProtocol, presets: [AppPreset] = []) {
        self.adb = adb
        self.presets = presets
    }

    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor] {
        let result = try await adb.run(.listThirdPartyPackages(device.serial), timeout: .seconds(5))
        let known = Dictionary(uniqueKeysWithValues: presets.map { ($0.packageName.value, $0) })
        let descriptors = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (AndroidPackageName, AppPreset?)? in
                let raw = line.hasPrefix("package:") ? String(line.dropFirst("package:".count)) : String(line)
                guard let packageName = try? AndroidPackageName(raw) else { return nil }
                return (packageName, known[raw])
            }
        let labels = await applicationLabels(
            for: descriptors.compactMap { $0.1 == nil ? $0.0 : nil },
            on: device
        )
        let resolved = descriptors.map { packageName, preset -> AppDescriptor in
            if let preset {
                return AppDescriptor(packageName: packageName, presentation: AppPresentation(
                    displayName: preset.displayName, symbolName: preset.symbolName, provenance: .preset
                ))
            }
            return AppDescriptor(packageName: packageName, presentation: AppPresentation(
                displayName: labels[packageName.value] ?? packageName.value,
                symbolName: nil,
                provenance: .generic
            ))
        }
        return resolved.sorted { left, right in
            let leftPreset = known[left.packageName.value]
            let rightPreset = known[right.packageName.value]
            switch (leftPreset?.favoriteOrder, rightPreset?.favoriteOrder) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.presentation.displayName.localizedStandardCompare(right.presentation.displayName) == .orderedAscending
            }
        }
    }

    private func applicationLabels(
        for packages: [AndroidPackageName],
        on device: DeviceDescriptor
    ) async -> [String: String] {
        let uncachedPackages = packages.filter { applicationLabelCache[$0.value] == nil }
        let lookup: @Sendable (AndroidPackageName) async -> (String, String?) = { [adb] packageName in
            let label = try? await adb.run(
                .applicationLabel(device.serial, packageName),
                timeout: .seconds(2)
            )
            let text = label.map { String(decoding: $0.stdout, as: UTF8.self) }
            return (packageName.value, text.flatMap(Self.applicationLabel))
        }
        let resolved = await withTaskGroup(of: (String, String?).self, returning: [String: String].self) { group in
            var iterator = uncachedPackages.makeIterator()
            for _ in 0..<min(4, packages.count) {
                guard let packageName = iterator.next() else { break }
                group.addTask { await lookup(packageName) }
            }
            var results: [String: String] = [:]
            while let (packageName, label) = await group.next() {
                if let label { results[packageName] = label }
                if let nextPackage = iterator.next() {
                    group.addTask { await lookup(nextPackage) }
                }
            }
            return results
        }
        applicationLabelCache.merge(resolved, uniquingKeysWith: { _, new in new })
        return packages.reduce(into: [:]) { labels, packageName in
            if let label = applicationLabelCache[packageName.value] {
                labels[packageName.value] = label
            }
        }
    }

    private static func applicationLabel(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("application-label:") else { continue }
            let raw = String(trimmed.dropFirst("application-label:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard !raw.isEmpty,
                  !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            return raw
        }
        return nil
    }

    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor] {
        let result = try await adb.run(.resolvePIDs(device.serial, packageName), timeout: .seconds(5))
        let prefix = packageName.value
        return String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ProcessDescriptor? in
                let fields = line.split(whereSeparator: \ .isWhitespace)
                guard fields.count >= 2, let pid = Int32(fields[0]) else { return nil }
                let name = String(fields[1])
                guard name == prefix || name.hasPrefix(prefix + ":") else { return nil }
                return ProcessDescriptor(pid: pid, name: name)
            }
            .sorted { $0.pid < $1.pid }
    }
}
