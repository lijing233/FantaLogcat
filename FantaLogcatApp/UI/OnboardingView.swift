import SwiftUI

struct DeviceSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingWireless = false

    var body: some View {
        Group {
            switch model.deviceConnection {
            case .scanning:
                ProgressView(model.copy("正在查找 Android 设备…", "Looking for Android devices…"))
                    .controlSize(.large)
            case .connected:
                ProgressView(model.copy("正在打开设备…", "Opening device…"))
                    .controlSize(.large)
            case .noDevice:
                connectionPage(status: nil)
            case .offline(let device):
                connectionPage(status: model.copy(
                    "\(device.displayName) 已离线，请重新连接。",
                    "\(device.displayName) went offline. Reconnect to continue."
                ))
            case .failed(let code):
                connectionPage(status: model.copy(
                    "无法检查设备：\(code)",
                    "Could not scan devices: \(code)"
                ))
            case .authorizationRequired(let device):
                authorizationPage(device)
            case .selectionRequired(let devices):
                selectionPage(devices)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingWireless) {
            WirelessDebugView().environmentObject(model)
        }
    }

    // MARK: - 连接页

    @ViewBuilder
    private func connectionPage(status: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "cable.connector")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(model.copy("连接 Android 设备", "Connect an Android device"))
                            .font(.system(size: 28, weight: .semibold))
                    }
                    Text(model.copy(
                        "连接后即可查看 Logcat、使用工具箱和快捷操作。",
                        "Once connected, you can view Logcat, use the toolbox, and more."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                }

                if let status {
                    Label(status, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                if isRecovering {
                    recoveryCard
                }

                connectCards

                if !model.recentDeviceConnections.isEmpty {
                    recentConnectionsSection
                }

                helpText
            }
            .padding(48)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private var isRecovering: Bool {
        if case .reconnectingSavedTCPIP = model.connectionRecoveryState { return true }
        return false
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.copy("正在恢复上次连接…", "Restoring the previous connection…"))
                    .font(.callout.weight(.semibold))
                Spacer()
                Button(model.copy("取消", "Cancel")) {
                    Task { await model.cancelRecovery() }
                }
                .buttonStyle(.borderless)
            }
            if let record = recoveringRecord {
                Text("\(record.displayName) · \(record.tcpIPAddress ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var recoveringRecord: RecentDeviceConnection? {
        guard case .reconnectingSavedTCPIP(let address) = model.connectionRecoveryState else { return nil }
        return model.recentDeviceConnections.first(where: { $0.tcpIPAddress == address })
    }

    // MARK: - 最近连接

    private var recentConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.copy("最近连接", "Recent connections"))
                .font(.headline)
            ForEach(model.recentDeviceConnections) { record in
                recentConnectionRow(record)
            }
        }
    }

    private func recentConnectionRow(_ record: RecentDeviceConnection) -> some View {
        HStack(spacing: 12) {
            Button {
                reconnect(record)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(record.displayName).fontWeight(.medium)
                        Text(record.transport.localizedLabel(model.copy))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(record.transport.tintColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(record.transport.tintColor)
                    }
                    Text(record.transport == .wirelessTCPIP
                         ? (record.tcpIPAddress ?? "")
                         : model.copy("已配对", "Paired"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if record.transport == .wirelessTCPIP {
                    Toggle(model.copy("自动恢复", "Auto-restore"), isOn: Binding(
                        get: { record.autoRestoreEnabled },
                        set: { model.setAutoRestore($0, serial: record.serial) }
                    ))
                }
                Button(model.copy("删除记录", "Delete"), role: .destructive) {
                    model.removeRecentDevice(serial: record.serial)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private func reconnect(_ record: RecentDeviceConnection) {
        switch record.transport {
        case .wirelessTCPIP:
            model.startRecovery(for: record)
        case .wirelessTLS, .usb, .emulator, .unknown:
            Task { await model.refreshDevices() }
        }
    }

    // MARK: - 连接卡片

    private var connectCards: some View {
        HStack(alignment: .top, spacing: 16) {
            connectCard(
                title: model.copy("USB 连接", "USB"),
                symbol: "cable.connector",
                detail: model.copy("连接数据线并开启 USB 调试。", "Plug in a cable and enable USB debugging."),
                actionTitle: model.copy("重新检测 USB 设备", "Rescan for USB devices"),
                action: { Task { await model.refreshDevices() } },
                identifier: "retryConnectionButton"
            )
            connectCard(
                title: model.copy("无线调试", "Wireless debugging"),
                symbol: "wifi",
                detail: model.copy("Android 11+ 扫码、配对码或 USB 转无线。", "Android 11+ QR pairing, pairing code, or USB to wireless."),
                actionTitle: model.copy("开始无线调试", "Start wireless debugging"),
                action: { isShowingWireless = true },
                identifier: "wirelessDebugButton"
            )
        }
    }

    private func connectCard(
        title: String,
        symbol: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: action) {
                Text(actionTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(identifier)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.primary.opacity(0.08))
        }
    }

    private var helpText: some View {
        Text(model.copy(
            "也可以在手机的开发者选项中使用无线调试。",
            "You can also use Wireless debugging from your phone's Developer options."
        ))
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - 授权 / 多设备

    @ViewBuilder
    private func authorizationPage(_ device: DeviceDescriptor) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(model.copy("请在手机上允许这台 Mac", "Allow this Mac on your phone"))
                .font(.title2.weight(.semibold))
            Text(model.copy(
                "\(device.displayName) 已连接，但尚未授权 USB 调试。解锁手机并点击“允许”。",
                "\(device.displayName) is connected, but needs USB debugging authorization. Unlock the phone and tap Allow."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520)
            Button(model.copy("我已允许，立即刷新", "I allowed it — scan again")) { Task { await model.refreshDevices() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("usbHelpButton")
        }
        .padding(48)
    }

    @ViewBuilder
    private func selectionPage(_ devices: [DeviceDescriptor]) -> some View {
        VStack(spacing: 20) {
            Text(model.copy("选择设备", "Choose a device"))
                .font(.title2.weight(.semibold))
            Text(model.copy(
                "发现多台可用 Android 设备，请选择要查看日志的设备。",
                "More than one Android device is ready. Choose the one whose logs you want to inspect."
            ))
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520)
            VStack(spacing: 10) {
                ForEach(devices) { device in
                    Button {
                        model.selectDevice(device)
                    } label: {
                        HStack {
                            Image(systemName: device.transport.symbolName)
                            VStack(alignment: .leading) {
                                Text(device.displayName).fontWeight(.medium)
                                Text(device.transport.localizedLabel(model.copy)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .frame(maxWidth: 460)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("deviceChoice.\(device.id)")
                }
            }
        }
        .padding(48)
    }
}
