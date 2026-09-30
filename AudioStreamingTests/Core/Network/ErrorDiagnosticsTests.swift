import Foundation
import XCTest

@testable import AudioStreaming

final class NetworkErrorTests: XCTestCase {
    func testFailureEqualityUsesNSErrorIdentity() {
        XCTAssertEqual(
            NetworkError.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            NetworkError.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        )
        XCTAssertNotEqual(
            NetworkError.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            NetworkError.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        )
    }

    func testServerErrorDescriptionIncludesStatusCode() {
        let details403 = makeResponseDetails(statusCode: 403, contentType: "text/html", url: "https://example.com/stream")
        let details404 = makeResponseDetails(statusCode: 404, contentType: nil, url: nil)
        let details500 = makeResponseDetails(statusCode: 500, contentType: "application/json", url: "https://example.com/api")

        XCTAssertEqual(
            NetworkError.serverError(details403).localizedDescription,
            "HTTP server error 403 contentType=text/html url=https://example.com/stream"
        )
        XCTAssertEqual(
            NetworkError.serverError(details404).localizedDescription,
            "HTTP server error 404 url=https://example.com"
        )
        XCTAssertEqual(
            NetworkError.serverError(details500).localizedDescription,
            "HTTP server error 500 contentType=application/json url=https://example.com/api"
        )

        let details403WithBody = details403.appendingBodySnippet("Access denied by origin")
        XCTAssertEqual(
            NetworkError.serverError(details403WithBody).localizedDescription,
            "HTTP server error 403 contentType=text/html url=https://example.com/stream bodySnippet=Access denied by origin"
        )
    }

    func testServerErrorPreservesStructuredResponseDetails() {
        let details = makeResponseDetails(
            statusCode: 403,
            contentType: "text/html; charset=utf-8",
            url: "https://worldwide-fm.radiocult.fm/stream",
            headers: [
                "cf-ray": "12345",
                "Server": "cloudflare"
            ]
        )

        let error = NetworkError.serverError(details)

        guard case let .serverError(responseDetails) = error else {
            return XCTFail("Expected serverError with response details.")
        }

        XCTAssertEqual(responseDetails.statusCode, 403)
        XCTAssertEqual(responseDetails.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(responseDetails.url, "https://worldwide-fm.radiocult.fm/stream")
        XCTAssertEqual(responseDetails.headers["cf-ray"], "12345")
        XCTAssertEqual(responseDetails.headers["Server"], "cloudflare")
        XCTAssertNil(responseDetails.bodySnippet)

        let detailsWithBody = responseDetails.appendingBodySnippet("Forbidden")
        XCTAssertEqual(detailsWithBody.bodySnippet, "Forbidden")
    }

    func testMissingDataDescription() {
        XCTAssertEqual(NetworkError.missingData.localizedDescription, "Missing audio data from network stream")
    }

    func testEngineFailureDescriptionIncludesUnderlyingNSErrorDetails() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        let description = AudioSystemError.engineFailure(.init(error: error)).localizedDescription

        XCTAssertTrue(description.contains("Audio engine couldn't start"))
        XCTAssertTrue(description.contains(NSURLErrorDomain))
        XCTAssertTrue(description.contains("\(NSURLErrorCannotConnectToHost)"))
    }

    func testNilUnderlyingErrorUsesPlainPrefix() {
        XCTAssertEqual(AudioSystemError.engineFailure(nil).localizedDescription, "Audio engine couldn't start")
        XCTAssertEqual(AudioSystemError.playerNotFound(nil).localizedDescription, "Player not found")
        XCTAssertEqual(AudioSystemError.playerStartError(nil).localizedDescription, "Player couldn't start")
    }

    func testUnderlyingAudioSystemErrorsIncludePrefixAndNSErrorDetails() {
        let playerNotFoundDescription =
            AudioSystemError.playerNotFound(.init(error: NSError(domain: "AudioUnit", code: -50))).localizedDescription
        XCTAssertTrue(playerNotFoundDescription.contains("Player not found"))
        XCTAssertTrue(playerNotFoundDescription.contains("AudioUnit"))
        XCTAssertTrue(playerNotFoundDescription.contains("-50"))

        let playerStartDescription =
            AudioSystemError.playerStartError(.init(error: NSError(domain: NSOSStatusErrorDomain, code: -10875))).localizedDescription
        XCTAssertTrue(playerStartDescription.contains("Player couldn't start"))
        XCTAssertTrue(playerStartDescription.contains(NSOSStatusErrorDomain))
        XCTAssertTrue(playerStartDescription.contains("-10875"))
    }

    private func makeResponseDetails(
        statusCode: Int,
        contentType: String?,
        url: String?,
        headers: [String: String] = [:]
    ) -> HTTPResponseDetails {
        var headerFields = headers
        if let contentType {
            headerFields["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(
            url: URL(string: url ?? "https://example.com")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )!
        return HTTPResponseDetails(response: response)
    }
}
