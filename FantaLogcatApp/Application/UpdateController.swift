import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateInstallationCoordinator: NSObject, SPUUpdaterDelegate {
    static let willInstallNotification = Notification.Name("FantaLogcatWillInstallUpdate")

    private let closePresentedSheets: @MainActor () -> Void

    init(closePresentedSheets: @escaping @MainActor () -> Void = UpdateInstallationCoordinator.closeApplicationSheets) {
        self.closePresentedSheets = closePresentedSheets
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        prepareForInstallation()
    }

    func prepareForInstallation() {
        closePresentedSheets()
        NotificationCenter.default.post(name: Self.willInstallNotification, object: nil)
    }

    private static func closeApplicationSheets() {
        let presentedSheets = NSApplication.shared.windows.compactMap(\.attachedSheet)
        for sheet in presentedSheets {
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
        }
    }
}

@MainActor
final class UpdateController: ObservableObject {
    let updaterController: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    private let installationCoordinator: UpdateInstallationCoordinator

    init(startingUpdater: Bool) {
        let installationCoordinator = UpdateInstallationCoordinator()
        self.installationCoordinator = installationCoordinator
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: installationCoordinator,
            userDriverDelegate: nil
        )
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        if startingUpdater, updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
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
