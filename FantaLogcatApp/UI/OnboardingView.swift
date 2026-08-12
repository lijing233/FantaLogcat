import SwiftUI

struct DeviceSelectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            switch model.deviceConnection {
            case .scanning:
                ProgressView(model.copy("正在查找 Android 设备…", "Looking for Android devices…"))
            case .noDevice:
                heading(
                    model.copy("设备已断开", "Device disconnected"),
                    detail: model.copy("请用 USB 连接手机、开启 USB 调试，并在手机上允许这台 Mac。连接恢复后会自动继续。", "Connect your phone with USB, enable USB debugging, then allow this Mac on the phone. FantaLogcat will resume automatically when it reconnects.")
                )
                Button(model.copy("立即刷新", "Scan again")) { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryConnectionButton")
                Text(model.copy("也可以在手机的开发者选项中使用无线调试。", "You can also use Wireless debugging from your phone’s Developer options."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .authorizationRequired(let device):
                heading(
                    model.copy("请在手机上允许这台 Mac", "Allow this Mac on your phone"),
                    detail: model.copy("(device.displayName) 已连接，但尚未授权 USB 调试。解锁手机并点击“允许”。", "\(device.displayName) is connected, but needs USB debugging authorization. Unlock the phone and tap Allow.")
                )
                Button(model.copy("我已允许，立即刷新", "I allowed it — scan again")) { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("usbHelpButton")
            case .selectionRequired(let devices):
                heading(
                    model.copy("选择设备", "Choose a device"),
                    detail: model.copy("发现多台可用 Android 设备，请选择要查看日志的设备。", "More than one Android device is ready. Choose the one whose logs you want to inspect.")
                )
                VStack(spacing: 10) {
                    ForEach(devices) { device in
                        Button {
                            model.selectDevice(device)
                        } label: {
                            HStack {
                                Image(systemName: symbol(for: device.transport))
                                VStack(alignment: .leading) {
                                    Text(device.displayName).fontWeight(.medium)
                                    Text(transportLabel(device.transport)).font(.caption).foregroundStyle(.secondary)
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
            case .connected:
                ProgressView(model.copy("正在打开设备…", "Opening device…"))
            case .offline(let device):
                heading(
                    model.copy("(device.displayName) 已离线", "\(device.displayName) is offline"),
                    detail: model.copy("请重新连接设备，或确认无线调试仍已开启。连接恢复后会自动继续。", "Reconnect the device or confirm that wireless debugging is still enabled. FantaLogcat will resume automatically when it reconnects.")
                )
                Button(model.copy("立即刷新", "Scan again")) { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
            case .failed(let code):
                heading(
                    model.copy("无法检查设备", "Could not scan devices"),
                    detail: model.copy("请重新连接手机后重试。错误：\(code)", "Try reconnecting your phone, then scan again. Error: \(code)")
                )
                Button(model.copy("立即刷新", "Scan again")) { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryConnectionButton")
            }
        }
        .padding(48)
    }

    @ViewBuilder
    private func heading(_ title: String, detail: String) -> some View {
        Text(title).font(.title2.weight(.semibold))
        Text(detail)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520)
    }

    private func symbol(for transport: DeviceTransport) -> String {
        switch transport {
        case .usb: "cable.connector"
        case .wireless: "wifi"
        case .emulator: "desktopcomputer"
        case .unknown: "iphone"
        }
    }

    private func transportLabel(_ transport: DeviceTransport) -> String {
        switch transport {
        case .usb: "USB"
        case .wireless: "Wireless debugging"
        case .emulator: "Android Emulator"
        case .unknown: "Android device"
        }
    }
}
