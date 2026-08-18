import XCTest
@testable import FantaLogcat

final class LogExporterTests: XCTestCase {
    private func export(_ message: String, redact: Bool) -> String {
        LogExporter.text(
            events: [.fixture(id: 1, message: message)],
            redact: redact
        )
    }

    func testRedactMasksTokenPasswordAndAPIKeyValues() {
        let result = export("token=abc123 password=hunter2 api_key=sk-live-1234", redact: true)

        XCTAssertTrue(result.contains("token=<redacted>"))
        XCTAssertTrue(result.contains("password=<redacted>"))
        XCTAssertTrue(result.contains("api_key=<redacted>"))
        XCTAssertFalse(result.contains("abc123"))
        XCTAssertFalse(result.contains("hunter2"))
        XCTAssertFalse(result.contains("sk-live-1234"))
    }

    func testRedactMasksSecretWithColonSeparator() {
        let result = export("secret: s3cr3tValue", redact: true)

        XCTAssertTrue(result.contains("secret:<redacted>"))
        XCTAssertFalse(result.contains("s3cr3tValue"))
    }

    func testRedactMasksAuthorizationBearerToken() {
        let result = export("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc", redact: true)

        XCTAssertTrue(result.contains("<redacted>"))
        XCTAssertFalse(result.contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    func testDisabledRedactionLeavesSecretsUnchanged() {
        let message = "token=abc123 password=hunter2"
        let result = export(message, redact: false)

        XCTAssertTrue(result.contains("token=abc123"))
        XCTAssertTrue(result.contains("password=hunter2"))
        XCTAssertFalse(result.contains("<redacted>"))
    }
}
