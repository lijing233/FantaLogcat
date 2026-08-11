import SwiftUI

@main
struct FantaLogcatApp: App {
    @StateObject private var model = AppModel(environment: .production)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
