//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest
import AudioToolbox.AudioFile

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
            [HeaderField.acceptRanges: "range",
             HeaderField.contentLength: "1000",
             HeaderField.contentType: "audio/mp3",
             IcyHeaderField.icyMentaint: "16000"
            ]
        let httpURLResponse = HTTPURLResponse(url: URL(string: "www.google.com")!,
                                              statusCode: 200,
                                              httpVersion: "",
                                              headerFields: headers)
        
        let output = parser.parse(input: httpURLResponse!)
        
        // Then
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileLength, 1000)
        XCTAssertEqual(output!.supportsSeek, true)
        XCTAssertEqual(output!.typeId, kAudioFileMP3Type)
        XCTAssertEqual(output!.metadataStep, 16000)
    }

    func testReturnCorrectValuesOnRequestThatSupportsSeekRanges() throws {
        // Given
        let parser = HTTPHeaderParser()
        
        // When
        let headers: [String: String] =
            [HeaderField.acceptRanges: "range",
             HeaderField.contentLength: "1000",
             HeaderField.contentType: "audio/mp3",
             HeaderField.contentRange: "100/1000"
            ]
        let httpURLResponse = HTTPURLResponse(url: URL(string: "www.google.com")!,
                                              statusCode: 206,
                                              httpVersion: "",
                                              headerFields: headers)
        
        let output = parser.parse(input: httpURLResponse!)
        
        // Then
        XCTAssertNotNil(output)
        XCTAssertEqual(output!.fileLength, 1000)
        XCTAssertEqual(output!.supportsSeek, true)
        XCTAssertEqual(output!.typeId, kAudioFileMP3Type)
    }
}
