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
                ProgressView("Looking for Android devices…")
            case .noDevice:
                heading("Connect an Android device", detail: "Connect your phone with USB, enable USB debugging, then allow this Mac on the phone.")
                Button("Scan again") { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retryConnectionButton")
                Text("You can also use Wireless debugging from your phone’s Developer options.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .authorizationRequired(let device):
                heading("Allow this Mac on your phone", detail: "(device.displayName) is connected, but needs USB debugging authorization. Unlock the phone and tap Allow, then scan again.")
                Button("I allowed it — scan again") { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("usbHelpButton")
            case .selectionRequired(let devices):
                heading("Choose a device", detail: "More than one Android device is ready. Choose the one whose logs you want to inspect.")
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
                ProgressView("Opening device…")
            case .offline(let device):
                heading("(device.displayName) is offline", detail: "Reconnect the device or confirm that wireless debugging is still enabled, then scan again.")
                Button("Scan again") { Task { await model.refreshDevices() } }
                    .buttonStyle(.borderedProminent)
            case .failed(let code):
                heading("Could not scan devices", detail: "Try reconnecting your phone, then scan again. Error: \(code)")
                Button("Scan again") { Task { await model.refreshDevices() } }
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
