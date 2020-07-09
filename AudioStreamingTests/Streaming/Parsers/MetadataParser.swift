//
//  MetadataParser.swift
//  AudioStreamingTests
//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest

@testable import AudioStreaming

class MetadataParserTests: XCTestCase {
    
    /// NOTE: Usual metadata values from icy stream are in the following format
    /// "StreamTtitle='A song title - Artist';StreamProducer='A producer'"
    
    func testParserOutputsCorrectResultFromCorrectData() throws {
        
        let string = "StreamTitle='A song - Artist';StreamSong='A song';StreamArtist='Artist';"
        let data = string.data(using: .utf8)
        
        let parser = MetadataParser()
        
        let output = parser.parse(input: data)
        
        switch output {
        case .success(let values):
            XCTAssertFalse(values.isEmpty)
            XCTAssertEqual(values["StreamTitle"], "A song - Artist")
            XCTAssertEqual(values["StreamSong"], "A song")
            XCTAssertEqual(values["StreamArtist"], "Artist")
        case .failure:
            XCTFail()
        }
        
    }
    
    func testParserOutputsFailureOnNilData() throws {
        let parser = MetadataParser()
        
        let output = parser.parse(input: nil)
        
        switch output {
        case .success:
            XCTFail()
        case .failure(let error):
            XCTAssertEqual(error, MetadataParsingError.unableToParse)
        }
    }
    
    func testParserOutputsFailureOnEmptyStringData() throws {
        
        let data = "".data(using: .utf8)
        let parser = MetadataParser()
        
        let output = parser.parse(input: data)
        
        switch output {
        case .success:
            XCTFail()
        case .failure(let error):
            XCTAssertEqual(error, MetadataParsingError.empty)
        }
    }

}
