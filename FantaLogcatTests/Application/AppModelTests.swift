import XCTest
@testable import FantaLogcat

@MainActor
final class AppModelTests: XCTestCase {
    func testNewModelStartsInPreparingADBPhase() {
        let model = AppModel(environment: .test)

        XCTAssertEqual(model.phase, .preparingADB)
    }
}
