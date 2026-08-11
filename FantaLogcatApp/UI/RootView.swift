import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .preparingADB:
                ProgressView("Preparing Android tools…")
            case .selectingDevice:
                Text("Select a device")
            case .selectingApp:
                Text("Select an app")
            case .viewingLogs:
                Text("Viewing logs")
            }
        }
        .frame(minWidth: 920, minHeight: 600)
    }
}
