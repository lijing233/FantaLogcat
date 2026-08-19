import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.isShowingSettings {
                SettingsView(
                    initialDraft: model.settingsDraft,
                    onClose: { model.isShowingSettings = false }
                )
            } else {
                switch model.phase {
                case .preparingADB:
                    ADBPreparationView()
                case .selectingDevice:
                    DeviceSelectionView()
                case .selectingApp:
                    AppSelectionView()
                case .toolbox:
                    if let service = model.adbToolService,
                       let scrcpy = model.scrcpyManager,
                       let device = model.selectedDevice {
                        ADBToolboxView(
                            service: service,
                            scrcpy: scrcpy,
                            device: device,
                            apps: model.availableApps
                        )
                    } else {
                        AppSelectionView()
                    }
                case .viewingLogs:
                    LogView()
                }
            }
        }
        .frame(minWidth: 920, minHeight: 600)
        .task {
            await model.startup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UpdateInstallationCoordinator.willInstallNotification)) { _ in
            model.isShowingSettings = false
        }
    }
}

private struct ADBPreparationView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            switch model.adbPreparation {
            case .checking:
                ProgressView("Checking Android tools…")
            case .licenseRequired:
                Text("Android tools are required")
                    .font(.title2.weight(.semibold))
                Text("FantaLogcat downloads the official Google Platform-Tools package (about 16 MB), verifies its SHA-256 checksum, and keeps it inside the app support folder.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Link("View Google license terms", destination: model.environment.adbLicenseURL)
                Button("Accept and install") {
                    Task { await model.installADB() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .installing:
                ProgressView("Downloading and verifying Android tools…")
                Text("Keep FantaLogcat open. The existing installation will not be replaced unless verification succeeds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let code):
                Text("Android tools could not be prepared")
                    .font(.title2.weight(.semibold))
                Text("Error: \(code)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await model.retryADB() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(48)
    }
}
