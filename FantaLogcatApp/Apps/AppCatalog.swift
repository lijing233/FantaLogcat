import Foundation

protocol AppCatalogProtocol: Sendable {
    func listApps(on device: DeviceDescriptor) async throws -> [AppDescriptor]
    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor]
}

actor AppCatalog: AppCatalogProtocol {
    private let adb: any ADBRuntimeProtocol
    private let presets: [AppPreset]

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
        let resolved = descriptors.map { packageName, preset -> AppDescriptor in
            if let preset {
                return AppDescriptor(packageName: packageName, presentation: AppPresentation(
                    displayName: preset.displayName, symbolName: preset.symbolName, provenance: .preset
                ))
            }
            return AppDescriptor(packageName: packageName, presentation: AppPresentation(
                displayName: packageName.value,
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

    func resolveProcesses(packageName: AndroidPackageName, on device: DeviceDescriptor) async throws -> [ProcessDescriptor] {
        if let viaPS = try? await resolveProcessesViaPS(packageName: packageName, on: device),
           !viaPS.isEmpty {
            return viaPS
        }

        // `ps -A -o PID,NAME` is not uniformly available across Android/OEM
        // builds. Fall back to `pidof` for the main process rather than
        // reporting "waiting for app" while the app is actually running.
        return await resolveProcessesViaPidOf(packageName: packageName, on: device)
    }

    private func resolveProcessesViaPS(
        packageName: AndroidPackageName,
        on device: DeviceDescriptor
    ) async throws -> [ProcessDescriptor] {
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

    private func resolveProcessesViaPidOf(
        packageName: AndroidPackageName,
        on device: DeviceDescriptor
    ) async -> [ProcessDescriptor] {
        // `pidof` matches the exact process name, so `:subprocess` children are
        // not discovered here; the `ps` path above already covers them.
        guard let result = try? await adb.run(.pidOf(device.serial, packageName), timeout: .seconds(5)) else {
            return []
        }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \ .isWhitespace)
            .compactMap { Int32(String($0)) }
            .map { ProcessDescriptor(pid: $0, name: packageName.value) }
            .sorted { $0.pid < $1.pid }
    }
}
