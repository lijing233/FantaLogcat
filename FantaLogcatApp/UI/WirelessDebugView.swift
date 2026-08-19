import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 使用 CoreImage 生成无线调试配对二维码。
enum WirelessQRGenerator {
    static func image(for payload: String, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

struct WirelessDebugView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case qr
        case code
        case usb

        var id: String { rawValue }
    }

    private enum QRPairingPhase: Equatable {
        case idle
        case checkingMDNS
        case waiting
        case pairing
        case connecting
        case connected
        case pairedButNotConnected
        case failed(String)
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode
    @State private var pairingKey: WirelessPairingKey?
    @State private var qrPhase: QRPairingPhase = .idle
    @State private var pairingTask: Task<Void, Never>?

    init(initialMode: Mode = .qr) {
        _mode = State(initialValue: initialMode)
    }

    @State private var pairingAddress = ""
    @State private var pairingCode = ""
    @State private var connectAddress = ""
    @State private var codeModeBusy = false
    @State private var codeModeMessage: String?

    @State private var tcpipPort = "5555"
    @State private var wifiIP = ""
    @State private var usbBusy = false
    @State private var usbMessage: String?

    @State private var isConfirmingRestart = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker(model.copy("连接方式", "Connection method"), selection: $mode) {
                        Text(model.copy("扫码配对（推荐）", "Pair with QR (recommended)")).tag(Mode.qr)
                        Text(model.copy("配对码", "Pairing code")).tag(Mode.code)
                        Text(model.copy("USB 转无线", "USB to wireless")).tag(Mode.usb)
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .qr: qrSection
                    case .code: codeSection
                    case .usb: usbSection
                    }

                    Divider()
                    managementSection
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            Task { await startQRPairing() }
        }
        .onDisappear(perform: cancelQRPairing)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.copy("无线调试", "Wireless debugging"))
                    .font(.title2.bold())
                if let device = model.selectedDevice {
                    Text("\(device.displayName) · \(device.serial.value)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(model.copy("完成", "Done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - 扫码配对

    @ViewBuilder
    private var qrSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch qrPhase {
            case .idle:
                ProgressView(model.copy("正在生成二维码…", "Generating QR code…"))
            case .checkingMDNS:
                ProgressView(model.copy("正在检查 mDNS 可用性…", "Checking mDNS availability…"))
            case .waiting:
                qrImage
                Text(model.copy(
                    "手机：开发者选项 → 无线调试 → 使用二维码配对设备 → 扫描。",
                    "Phone: Developer options → Wireless debugging → Pair device with QR code → Scan."
                ))
                Label(
                    model.copy("等待手机扫码…（未扫码将自动刷新二维码）", "Waiting for the phone to scan… (the QR auto-refreshes if not scanned)"),
                    systemImage: "qrcode.viewfinder"
                )
                .foregroundStyle(.secondary)
            case .pairing:
                ProgressView(model.copy("正在安全配对…", "Pairing securely…"))
            case .connecting:
                ProgressView(model.copy("正在等待设备连接…", "Waiting for the device to connect…"))
            case .connected:
                Label(
                    model.copy("已连接：\(model.selectedDevice?.displayName ?? "")（无线）", "Connected: \(model.selectedDevice?.displayName ?? "") (wireless)"),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                Button(model.copy("完成", "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
            case .pairedButNotConnected:
                Label(
                    model.copy("配对成功，但尚未连接", "Paired, but not connected yet"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Text(model.copy(
                    "设备可能仍在通过 mDNS 自动连接，或连接失败。可稍后重试。",
                    "The device may still be auto-connecting over mDNS, or the connection failed. You can retry shortly."
                ))
                .foregroundStyle(.secondary)
                HStack {
                    Button(model.copy("重试连接", "Retry connection")) {
                        startAdoptionPolling()
                    }
                    .buttonStyle(.bordered)
                    Button(model.copy("改用配对码", "Use pairing code")) { mode = .code }
                        .buttonStyle(.bordered)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button(model.copy("重新生成二维码", "Regenerate QR")) {
                        Task { await startQRPairing() }
                    }
                    .buttonStyle(.bordered)
                    Button(model.copy("改用配对码", "Use pairing code")) { mode = .code }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var qrImage: some View {
        if let key = pairingKey, let cgImage = WirelessQRGenerator.image(for: key.qrPayload) {
            Image(decorative: cgImage, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: 200, height: 200)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func startQRPairing() async {
        guard !isQRInProgress else { return }
        cancelQRPairing()
        guard let service = model.wirelessService else {
            qrPhase = .failed(model.copy("无线服务不可用。", "Wireless service unavailable."))
            return
        }
        qrPhase = .checkingMDNS
        guard await service.mDNSAvailable() else {
            qrPhase = .failed(model.copy(
                "当前网络不支持 mDNS 自动发现，请改用配对码。",
                "This network does not support mDNS auto-discovery. Use a pairing code instead."
            ))
            return
        }
        await model.snapshotKnownDeviceSerials()
        pairingTask = Task {
            await runQRPairingLoop(service: service)
        }
    }

    /// 连续循环：生成二维码 → 等待扫码 → 配对 → 确认连接；60 秒未扫码自动刷新二维码。
    private func runQRPairingLoop(service: any WirelessDebugServiceProtocol) async {
        while !Task.isCancelled {
            let key = WirelessPairingKey.make()
            pairingKey = key
            qrPhase = .waiting
            do {
                let endpoint = try await waitForPairingEndpoint(service: service, serviceName: key.serviceName)
                qrPhase = .pairing
                try await service.pair(endpoint: endpoint, secret: key.psk)
                pairingKey = nil
                await pollForAdoption()
                return
            } catch WirelessDebugError.pairingTimedOut {
                // 超时：清除旧密钥，自动刷新二维码继续等待。
                pairingKey = nil
                continue
            } catch {
                pairingKey = nil
                guard !Task.isCancelled else { return }
                qrPhase = .failed(errorMessage(error))
                return
            }
        }
    }

    private var isQRInProgress: Bool {
        switch qrPhase {
        case .checkingMDNS, .waiting, .pairing, .connecting: true
        case .idle, .connected, .pairedButNotConnected, .failed: false
        }
    }

    /// 配对成功后轮询，直到新增 TLS 设备出现并完成切换；超时则提示"尚未连接"。
    private func pollForAdoption(timeout: Duration = .seconds(15)) async {
        qrPhase = .connecting
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if Task.isCancelled { return }
            if await model.adoptWirelessDevice() {
                qrPhase = .connected
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if await model.adoptWirelessDevice() {
            qrPhase = .connected
        } else {
            qrPhase = .pairedButNotConnected
        }
    }

    /// "重试连接"入口：再次轮询等待设备连接。
    private func startAdoptionPolling() {
        pairingTask?.cancel()
        pairingTask = Task {
            await pollForAdoption()
        }
    }

    private func waitForPairingEndpoint(
        service: any WirelessDebugServiceProtocol,
        serviceName: String
    ) async throws -> ADBEndpoint {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let endpoint = try? await service.discoverPairingEndpoint(serviceName: serviceName) {
                return endpoint
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw WirelessDebugError.pairingTimedOut
    }

    private func cancelQRPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingKey = nil
    }

    // MARK: - 配对码

    private var codeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.copy(
                "手机：无线调试 → 使用配对码配对设备，依次填写配对地址、配对码和连接地址。",
                "Phone: Wireless debugging → Pair device with pairing code, then fill in the pairing address, code, and connect address."
            ))
            .foregroundStyle(.secondary)
            labeledField(model.copy("配对地址（IP:端口）", "Pairing address (IP:port)"), text: $pairingAddress)
                .help(model.copy("例如 192.168.1.5:37755", "e.g. 192.168.1.5:37755"))
            labeledField(model.copy("6 位配对码", "6-digit pairing code"), text: $pairingCode)
            Divider()
            labeledField(model.copy("连接地址（IP:端口）", "Connect address (IP:port)"), text: $connectAddress)
                .help(model.copy("例如 192.168.1.5:5555", "e.g. 192.168.1.5:5555"))
            Button(model.copy("配对并连接", "Pair and connect")) {
                Task { await pairWithCode() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(codeModeBusy || !isCodeFormValid)
            if codeModeBusy { ProgressView().controlSize(.small) }
            if let codeModeMessage {
                Text(codeModeMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var isCodeFormValid: Bool {
        !pairingAddress.isEmpty && pairingCode.count == 6 && !connectAddress.isEmpty
    }

    private func pairWithCode() async {
        guard let service = model.wirelessService else { return }
        codeModeBusy = true
        defer { codeModeBusy = false }
        do {
            guard let pairEndpoint = WirelessDebugService.parseAddress(pairingAddress) else {
                throw ADBValidationError.invalidEndpoint
            }
            let code = try ADBPairingCode(pairingCode)
            guard let connectEndpoint = WirelessDebugService.parseAddress(connectAddress) else {
                throw ADBValidationError.invalidEndpoint
            }
            await model.snapshotKnownDeviceSerials()
            try await service.pair(endpoint: pairEndpoint, secret: code.value)
            try await service.connect(endpoint: connectEndpoint)
            await model.adoptWirelessDevice()
            codeModeMessage = model.copy("已连接并选择无线设备。", "Connected and selected the wireless device.")
        } catch {
            codeModeMessage = errorMessage(error)
        }
    }

    // MARK: - USB 转无线

    @ViewBuilder
    private var usbSection: some View {
        if let device = model.selectedDevice, device.transport == .usb {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.copy("当前设备：\(device.displayName)（USB）", "Current device: \(device.displayName) (USB)"))
                    .font(.callout.weight(.semibold))
                labeledField(model.copy("端口", "Port"), text: $tcpipPort)
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    labeledField(model.copy("手机 Wi-Fi IP", "Phone Wi-Fi IP"), text: $wifiIP)
                    Button {
                        Task { await autoFetchWiFiIP() }
                    } label: {
                        Label(model.copy("自动获取", "Auto-detect"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(usbBusy)
                }
                Button(model.copy("连接并切换", "Connect and switch")) {
                    Task { await connectAndSwitch() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(usbBusy || wifiIP.isEmpty)
                if usbBusy { ProgressView().controlSize(.small) }
                if let usbMessage {
                    Text(usbMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            .onAppear {
                Task { await autoFetchWiFiIP() }
            }
        } else {
            Text(model.copy(
                "USB 转无线需要当前已有 USB 设备连接，请先通过数据线连接设备。",
                "USB-to-wireless requires an existing USB connection. Connect a device over USB first."
            ))
            .foregroundStyle(.secondary)
        }
    }

    private func autoFetchWiFiIP() async {
        guard wifiIP.isEmpty,
              let service = model.wirelessService,
              let device = model.selectedDevice,
              device.transport == .usb else { return }
        do {
            if let ip = try await service.wifiIPAddress(serial: device.serial), !ip.isEmpty {
                wifiIP = ip
                usbMessage = model.copy("已自动获取手机 Wi-Fi IP。", "Auto-detected the phone's Wi-Fi IP.")
            } else {
                usbMessage = model.copy("未能自动获取 Wi-Fi IP，请手动填写。", "Could not auto-detect the Wi-Fi IP. Enter it manually.")
            }
        } catch {
            usbMessage = model.copy("未能自动获取 Wi-Fi IP，请手动填写。", "Could not auto-detect the Wi-Fi IP. Enter it manually.")
        }
    }

    private func connectAndSwitch() async {
        usbBusy = true
        defer { usbBusy = false }
        do {
            let port = Int(tcpipPort) ?? 5_555
            let switched = try await model.switchUSBToWireless(port: port, wifiIP: wifiIP)
            if switched {
                usbMessage = model.copy(
                    "无线连接已验证，现在可以拔掉数据线。",
                    "Wireless connection verified. You can now unplug the cable."
                )
            } else {
                usbMessage = model.copy(
                    "已发起连接，但尚未完成切换，请稍后在设备菜单查看。",
                    "Connection initiated, but the switch has not completed. Check the device menu shortly."
                )
            }
        } catch {
            usbMessage = errorMessage(error)
        }
    }

    // MARK: - 连接管理

    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.copy("无线连接管理", "Wireless connection management"))
                .font(.headline)
            if let device = model.selectedDevice, device.transport.isWireless {
                Button(model.copy("断开当前无线设备", "Disconnect this wireless device")) {
                    Task {
                        await model.disconnectWirelessDevice()
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
            }
            Button(model.copy("断开全部无线设备", "Disconnect all wireless devices")) {
                Task { await model.disconnectAllWirelessDevices() }
            }
            .buttonStyle(.bordered)
            if model.selectedDevice?.transport == .wirelessTCPIP {
                Button(model.copy("恢复 USB 模式", "Restore USB mode")) {
                    Task { await model.restoreUSB() }
                }
                .buttonStyle(.bordered)
            }
            Divider()
            Text(model.copy("高级操作", "Advanced"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Button(model.copy("重启本机 ADB 服务…", "Restart ADB server…"), role: .destructive) {
                isConfirmingRestart = true
            }
            .buttonStyle(.bordered)
            .alert(
                model.copy("确认重启 ADB 服务？", "Restart ADB server?"),
                isPresented: $isConfirmingRestart
            ) {
                Button(model.copy("重启", "Restart"), role: .destructive) {
                    Task { await model.restartADBServer() }
                }
                Button(model.copy("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(model.copy("这会断开所有已连接设备。", "This disconnects all connected devices."))
            }
        }
    }

    // MARK: - 辅助

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if error is CancellationError {
            return model.copy("操作已取消。", "Operation cancelled.")
        }
        if let wirelessError = error as? WirelessDebugError {
            switch wirelessError {
            case .pairingTimedOut:
                return model.copy(
                    "未在 60 秒内发现配对服务。请确认手机与 Mac 在同一网络，且网络未屏蔽 mDNS。",
                    "No pairing service appeared within 60 seconds. Ensure the phone and Mac share the same network and mDNS is not blocked."
                )
            case .wifiIPUnavailable, .usbDeviceRequired:
                break
            }
        }
        if let validation = error as? ADBValidationError {
            switch validation {
            case .invalidEndpoint:
                return model.copy("请输入有效的 IP 与端口。", "Enter a valid IP and port.")
            case .invalidPairingCode:
                return model.copy("请输入 6 位数字配对码。", "Enter a 6-digit pairing code.")
            default:
                break
            }
        }
        if let adbError = error as? ADBError, case .commandFailed(_, let summary) = adbError, !summary.isEmpty {
            return summary
        }
        return model.copy("操作失败，请检查设备与网络后重试。", "Operation failed. Check the device and network and try again.")
    }
}
