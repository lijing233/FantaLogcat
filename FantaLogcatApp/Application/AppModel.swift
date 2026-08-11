import SwiftUI

enum AppPhase: Equatable {
    case preparingADB
    case selectingDevice
    case selectingApp
    case viewingLogs
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .preparingADB

    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}
