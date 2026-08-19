import SwiftUI

/// 当前设备菜单：展示当前设备连接方式，并提供无线调试入口与连接管理动作。
/// 用于应用选择、日志、工具箱三个页面的顶部。
struct CurrentDeviceMenu: View {
    private enum MenuAlert {
        case confirmSwitchToWireless
        case switchFailed(String)
        case confirmRestart
    }

    @EnvironmentObject private var model: AppModel
    @State private var isShowingWireless = false
    @State private var activeAlert: MenuAlert?
    @State private var isShowingAlert = false
    @State private var isSwitchingToWireless = false

    var body: some View {
        Menu {
            if let device = model.selectedDevice {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.copy("当前连接", "Current connection"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(device.transport.detailText(model.copy))
                        .font(.callout)
                    Text(device.serial.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }

            if model.selectedDevice?.transport == .usb {
                Button {
                    present(.confirmSwitchToWireless)
                } label: {
                    Label(model.copy("USB 转无线", "USB to wireless"), systemImage: "arrow.triangle.swap")
                }
                .disabled(isSwitchingToWireless)
            }

            Button {
                isShowingWireless = true
            } label: {
                Label(model.copy("管理无线连接", "Manage wireless connection"), systemImage: "wifi")
            }

            if model.selectedDevice?.transport.isWireless == true {
                Button(role: .destructive) {
                    Task { await model.disconnectWirelessDevice() }
                } label: {
                    Label(model.copy("断开当前无线设备", "Disconnect this wireless device"), systemImage: "xmark.circle")
                }
            }

            Button {
                Task { await model.disconnectAllWirelessDevices() }
            } label: {
                Label(model.copy("断开全部无线设备", "Disconnect all wireless devices"), systemImage: "wifi.slash")
            }

            if model.selectedDevice?.transport == .wirelessTCPIP {
                Button {
                    Task { await model.restoreUSB() }
                } label: {
                    Label(model.copy("恢复 USB 模式", "Restore USB mode"), systemImage: "cable.connector")
                }
            }

            Divider()

            Button(role: .destructive) {
                present(.confirmRestart)
            } label: {
                Label(model.copy("重启本机 ADB 服务…", "Restart ADB server…"), systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 6) {
                if isSwitchingToWireless {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.copy("切换中…", "Switching…"))
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: transport.symbolName)
                    Text(deviceLabel)
                        .lineLimit(1)
                    Text(transportLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(transport.tintColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(transport.tintColor)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .sheet(isPresented: $isShowingWireless) {
            WirelessDebugView().environmentObject(model)
        }
        .alert(alertTitle, isPresented: $isShowingAlert) {
            switch activeAlert {
            case .confirmSwitchToWireless:
                Button(model.copy("切换", "Switch"), role: .destructive) {
                    Task { await performSwitchToWireless() }
                }
                Button(model.copy("取消", "Cancel"), role: .cancel) {}
            case .switchFailed:
                Button(model.copy("好", "OK"), role: .cancel) {}
            case .confirmRestart:
                Button(model.copy("重启", "Restart"), role: .destructive) {
                    Task { await model.restartADBServer() }
                }
                Button(model.copy("取消", "Cancel"), role: .cancel) {}
            case nil:
                EmptyView()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var transport: DeviceTransport {
        model.selectedDevice?.transport ?? .unknown
    }

    private var transportLabel: String {
        transport.localizedLabel(model.copy)
    }

    private func present(_ alert: MenuAlert) {
        activeAlert = alert
        isShowingAlert = true
    }

    private var alertTitle: String {
        switch activeAlert {
        case .confirmSwitchToWireless:
            model.copy("切换为无线调试？", "Switch to wireless debugging?")
        case .switchFailed:
            model.copy("切换失败", "Switch failed")
        case .confirmRestart:
            model.copy("确认重启 ADB 服务？", "Restart ADB server?")
        case nil:
            ""
        }
    }

    private var alertMessage: String {
        switch activeAlert {
        case .confirmSwitchToWireless:
            model.copy(
                "将通过 USB 启用 TCP/IP 调试，自动获取 Wi-Fi IP 并切换到无线连接。",
                "Enables TCP/IP debugging over USB, auto-detects the Wi-Fi IP, and switches to wireless."
            )
        case .switchFailed(let message):
            message
        case .confirmRestart:
            model.copy("这会断开所有已连接设备。", "This disconnects all connected devices.")
        case nil:
            ""
        }
    }

    private func performSwitchToWireless() async {
        isSwitchingToWireless = true
        defer { isSwitchingToWireless = false }
        do {
            let switched = try await model.switchUSBToWireless()
            if !switched {
                present(.switchFailed(model.copy(
                    "连接未完成，请确认手机 Wi-Fi 已开启且与 Mac 同一网络后重试。",
                    "The switch did not complete. Confirm the phone's Wi-Fi is on and shares the same network as this Mac, then retry."
                )))
            }
        } catch {
            present(.switchFailed(switchErrorMessage(error)))
        }
    }

    private func switchErrorMessage(_ error: Error) -> String {
        if error is CancellationError {
            return model.copy("操作已取消。", "Operation cancelled.")
        }
        if let wirelessError = error as? WirelessDebugError {
            switch wirelessError {
            case .wifiIPUnavailable:
                return model.copy(
                    "未能获取手机 Wi-Fi IP，请确认 USB 已连接且手机 Wi-Fi 已开启。",
                    "Could not read the phone's Wi-Fi IP. Confirm USB is connected and Wi-Fi is enabled."
                )
            case .usbDeviceRequired:
                return model.copy("请先通过 USB 连接设备。", "Connect a device over USB first.")
            case .pairingTimedOut:
                break
            }
        }
        if let validation = error as? ADBValidationError, validation == .invalidEndpoint {
            return model.copy("请输入有效的 IP 与端口。", "Enter a valid IP and port.")
        }
        if let adbError = error as? ADBError, case .commandFailed(_, let summary) = adbError, !summary.isEmpty {
            return summary
        }
        return model.copy("切换失败，请检查设备与网络后重试。", "Switch failed. Check the device and network and try again.")
    }

    private var deviceLabel: String {
        model.selectedDevice?.displayName ?? model.copy("设备", "Device")
    }
}
