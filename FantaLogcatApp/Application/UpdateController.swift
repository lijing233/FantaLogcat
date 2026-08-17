import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    init(startingUpdater: Bool) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set {
            updaterController.updater.automaticallyDownloadsUpdates = newValue
            objectWillChange.send()
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
