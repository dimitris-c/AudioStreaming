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
        XCTAssertEqual(NetworkError.serverError(statusCode: 403).localizedDescription, "HTTP server error 403")
        XCTAssertEqual(NetworkError.serverError(statusCode: 404).localizedDescription, "HTTP server error 404")
        XCTAssertEqual(NetworkError.serverError(statusCode: 500).localizedDescription, "HTTP server error 500")
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
}
