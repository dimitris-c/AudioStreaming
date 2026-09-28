//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox.AudioFile
import XCTest

@testable import AudioStreaming

class HTTPHeaderParserTests: XCTestCase {
    func testReturnNilWhenHeaderFieldsAreEmpty() throws {
        // Given
        let parser = HTTPHeaderParser()

        // When
        let httpURLResponse = HTTPURLResponse(url: URL(string: "www.google.com")!,
                                              statusCode: 200,
                                              httpVersion: "",
                                              headerFields: [:])

        let output = parser.parse(input: httpURLResponse!)

        // Then
        // should return nil on empty headers
        XCTAssertNil(output)
    }

    func testReturnCorrectValuesOnNormalRequest() throws {
        // Given
        let parser = HTTPHeaderParser()

        // When
        let headers: [String: String] =
            [HeaderField.contentLength: "1000",
             HeaderField.contentType: "audio/mp3",
             IcyHeaderField.icyMetaint: "16000"]
        let httpURLResponse = HTTPURLResponse(url: URL(string: "www.google.com")!,
                                              statusCode: 200,
                                              httpVersion: "",
                                              headerFields: headers)

        let output = parser.parse(input: httpURLResponse!)

        // Then
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileLength, 1000)
        XCTAssertEqual(output!.typeId, kAudioFileMP3Type)
        XCTAssertEqual(output!.metadataStep, 16000)
        XCTAssertEqual(output!.contentTypeHint, .finite)
    }

    func testReturnCorectValuesOnCaseInsensitiveHeaderFiels() throws {
        // Given
        let parser = HTTPHeaderParser()

        // When
        let headers: [String: String] =
            [HeaderField.contentLength.lowercased(): "1000",
             HeaderField.contentType.lowercased(): "audio/mp3",
             IcyHeaderField.icyMetaint.lowercased(): "16000"]
        let httpURLResponse = HTTPURLResponse(url: URL(string: "www.google.com")!,
                                              statusCode: 200,
                                              httpVersion: "",
                                              headerFields: headers)

        let output = parser.parse(input: httpURLResponse!)

        // Then
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileLength, 1000)
        XCTAssertEqual(output!.typeId, kAudioFileMP3Type)
        XCTAssertEqual(output!.metadataStep, 16000)
        XCTAssertEqual(output!.contentTypeHint, .finite)
    }

    func testDetectsLengthlessIcyResponseAsLive() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/live")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                HeaderField.contentType: "audio/mpeg",
                IcyHeaderField.icyMetaint: "1024",
                "icy-name": "Test Radio"
            ]
        )!

        let output = HTTPHeaderParser().parse(input: response)

        XCTAssertEqual(output?.contentTypeHint, .live)
    }

    func testKeepsAmbiguousLengthlessResponseOnDemand() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/generated-audio")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                HeaderField.contentType: "audio/mpeg",
                "Transfer-Encoding": "chunked",
                "Cache-Control": "no-cache"
            ]
        )!

        let output = HTTPHeaderParser().parse(input: response)

        XCTAssertEqual(output?.contentTypeHint, .unknown)
    }
}
