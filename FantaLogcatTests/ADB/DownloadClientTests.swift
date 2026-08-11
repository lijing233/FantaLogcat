import CryptoKit
import Foundation
import XCTest
@testable import FantaLogcat

final class DownloadClientTests: XCTestCase {
    func testStreamsToFileAndReturnsIncrementalDigest() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadClient-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let client = makeClient()

        let receipt = try await client.download(
            from: URL(string: "https://fixture.test/success")!,
            to: destination,
            maximumBytes: 100
        )

        let expected = Data("hello".utf8)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertEqual(receipt.byteCount, expected.count)
        XCTAssertEqual(
            receipt.sha256,
            SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        )
    }

    func testAbortsWhenStreamExceedsLimitWithoutContentLength() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadClient-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let client = makeClient()

        do {
            _ = try await client.download(
                from: URL(string: "https://fixture.test/oversized")!,
                to: destination,
                maximumBytes: 1_024
            )
            XCTFail("Expected size limit")
        } catch {
            XCTAssertEqual(error as? ADBInstallerError, .archiveTooLarge)
        }

        let writtenBytes = (try? Data(contentsOf: destination).count) ?? 0
        XCTAssertLessThanOrEqual(writtenBytes, 1_024)
    }

    private func makeClient() -> URLSessionDownloadClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSessionDownloadClient(session: URLSession(configuration: configuration))
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = request.url?.path == "/oversized"
            ? Data(repeating: 0x41, count: 1_025)
            : Data("hello".utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
