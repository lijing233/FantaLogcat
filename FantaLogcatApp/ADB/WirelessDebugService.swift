import Foundation

enum WirelessDebugError: Error, Equatable {
    case pairingTimedOut
    case wifiIPUnavailable
    case usbDeviceRequired
}

protocol WirelessDebugServiceProtocol: Sendable {
    func mDNSAvailable() async -> Bool
    func discoverPairingEndpoint(serviceName: String) async throws -> ADBEndpoint?
    func pair(endpoint: ADBEndpoint, secret: String) async throws
    func connect(endpoint: ADBEndpoint) async throws
    func enableTCPIP(serial: ADBDeviceSerial, port: Int) async throws
    func restoreUSB(serial: ADBDeviceSerial) async throws
    func disconnect(address: String?) async throws
    func restartServer() async throws
    func wifiIPAddress(serial: ADBDeviceSerial) async throws -> String?
}

/// 一次性无线调试配对密钥：仅保存在内存，配对成功、取消或超时即丢弃。
struct WirelessPairingKey: Sendable, Equatable {
    let serviceName: String
    let psk: String

    static func make() -> WirelessPairingKey {
        WirelessPairingKey(
            serviceName: "studio-\(randomString(10))",
            psk: randomString(11)
        )
    }

    /// Android 无线调试扫码配对载荷（S 为 mDNS 服务实例名，P 为随机 PSK）。
    var qrPayload: String {
        "WIFI:T:ADB;S:\(serviceName);P:\(psk);;"
    }

    /// 不含 QR 分隔符（; : ,）与转义符的可打印 ASCII 字母表。
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{}<>?/"
    )

    private static func randomString(_ count: Int) -> String {
        String((0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}

actor WirelessDebugService: WirelessDebugServiceProtocol {
    private let adb: any ADBRuntimeProtocol

    init(adb: any ADBRuntimeProtocol) {
        self.adb = adb
    }

    /// mDNS 是否可用（`adb mdns check` 以非零退出码表示不可用）。
    func mDNSAvailable() async -> Bool {
        (try? await adb.run(.mdnsCheck, timeout: .seconds(5))) != nil
    }

    /// 通过 mDNS 发现扫码配对服务，优先匹配给定服务名，否则回退到第一个配对服务。
    func discoverPairingEndpoint(serviceName: String) async throws -> ADBEndpoint? {
        let result = try await adb.run(.mdnsServices, timeout: .seconds(5))
        let output = String(decoding: result.stdout, as: UTF8.self)
        return Self.parsePairingEndpoint(from: output, serviceName: serviceName)
    }

    func pair(endpoint: ADBEndpoint, secret: String) async throws {
        _ = try await adb.run(
            .pair(endpoint, secret: secret),
            timeout: .seconds(30)
        )
    }

    func connect(endpoint: ADBEndpoint) async throws {
        _ = try await adb.run(.connect(endpoint), timeout: .seconds(15))
    }

    func enableTCPIP(serial: ADBDeviceSerial, port: Int) async throws {
        guard (1...65_535).contains(port) else { throw ADBValidationError.invalidEndpoint }
        _ = try await adb.run(.tcpip(serial, port: port), timeout: .seconds(15))
    }

    func restoreUSB(serial: ADBDeviceSerial) async throws {
        _ = try await adb.run(.usb(serial), timeout: .seconds(15))
    }

    func disconnect(address: String?) async throws {
        _ = try await adb.run(.disconnect(address: address), timeout: .seconds(15))
    }

    func restartServer() async throws {
        _ = try await adb.run(.killServer, timeout: .seconds(15))
    }

    /// 通过 USB 读取设备的 Wi-Fi IPv4 地址，供 USB 转无线自动预填。
    func wifiIPAddress(serial: ADBDeviceSerial) async throws -> String? {
        let result = try await adb.run(.deviceIPAddress(serial), timeout: .seconds(10))
        return Self.parseWiFiIP(from: String(decoding: result.stdout, as: UTF8.self))
    }

    // MARK: - Parsing

    /// 从 `adb mdns services` 输出中解析 `_adb-tls-pairing._tcp` 服务地址。
    /// 仅返回与本次二维码请求的服务实例名精确匹配的记录，避免误连其它配对中的设备。
    static func parsePairingEndpoint(from output: String, serviceName: String) -> ADBEndpoint? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains("_adb-tls-pairing._tcp") else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.contains(serviceName) else { continue }
            for token in tokens {
                if let endpoint = parseAddress(token) {
                    return endpoint
                }
            }
        }
        return nil
    }

    /// 解析 `192.168.1.5:37755` 或 `[fe80::1]:37755` 形式的地址。
    static func parseAddress(_ address: String) -> ADBEndpoint? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let hostStart = trimmed.index(after: trimmed.startIndex)
            guard close > hostStart else { return nil }
            let host = String(trimmed[hostStart..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.first == ":" else { return nil }
            guard let port = Int(rest.dropFirst()) else { return nil }
            return try? ADBEndpoint(host: host, port: port)
        }
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        guard let port = Int(trimmed[trimmed.index(after: colon)...]) else { return nil }
        return try? ADBEndpoint(host: host, port: port)
    }

    /// 从 `adb shell ip -o -f inet addr show` 输出中解析设备 Wi-Fi IPv4 地址。
    /// 优先 `wlan*` 接口，跳过 loopback、链路本地与 USB 共享网络（rndis/usb）。
    static func parseWiFiIP(from output: String) -> String? {
        var fallback: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: \.isWhitespace).map(String.init)
            // 期望格式: "<ifindex>: <ifname> inet <ip>/<prefix> ..."
            guard tokens.count >= 4, tokens[2] == "inet" else { continue }
            let interface = tokens[1]
            let address = tokens[3].split(separator: "/").first.map(String.init) ?? ""
            guard isIPv4(address) else { continue }
            if interface == "lo" || address.hasPrefix("169.254.") { continue }
            if interface.hasPrefix("rndis") || interface.hasPrefix("usb") { continue }
            if interface.hasPrefix("wlan") { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let number = Int(part), (0...255).contains(number) else { return false }
            return true
        }
    }
}
