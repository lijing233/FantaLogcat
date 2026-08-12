import SwiftUI

struct AppSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    private var visibleApps: [AppDescriptor] {
        guard !search.isEmpty else { return model.availableApps }
        return model.availableApps.filter {
            $0.presentation.displayName.localizedCaseInsensitiveContains(search)
                || $0.packageName.value.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose an app").font(.title2.weight(.semibold))
            Text("Select the game or app whose logs you want to view.").foregroundStyle(.secondary)
            TextField("Search installed apps", text: $search).textFieldStyle(.roundedBorder)
            if model.availableApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed").font(.title)
                    Text("No third-party apps found").font(.headline)
                    Text("Install or open an app on the selected device, then try again.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Button("Refresh apps") { Task { await model.loadApps() } }
            } else {
                List(visibleApps) { app in
                    Button { model.selectApp(app) } label: {
                        Label(app.presentation.displayName, systemImage: app.presentation.symbolName ?? "app.dashed")
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(32)
        .task { await model.loadApps() }
    }
}
