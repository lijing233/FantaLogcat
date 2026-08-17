import XCTest
@testable import FantaLogcat

@MainActor
final class UpdateInstallationCoordinatorTests: XCTestCase {
    func testPreparingForInstallationClosesPresentedSheets() {
        var closeCount = 0
        let coordinator = UpdateInstallationCoordinator {
            closeCount += 1
        }

        coordinator.prepareForInstallation()

        XCTAssertEqual(closeCount, 1)
    }
}
