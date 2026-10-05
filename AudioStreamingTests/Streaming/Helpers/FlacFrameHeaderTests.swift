//
//  FlacFrameHeaderTests.swift
//  AudioStreamingTests
//

import XCTest
@testable import AudioStreaming

final class FlacFrameHeaderTests: XCTestCase {
    // Frame headers taken from a 44.1 kHz FLAC file encoded with a fixed block size of 4608 samples
    private let firstFrame: [UInt8] = [0xFF, 0xF8, 0x59, 0x88, 0x00, 0x8A]
    private let frame1000: [UInt8] = [0xFF, 0xF8, 0x59, 0x88, 0xCF, 0xA8, 0xC0]
    // last frame (number 2296) is 4032 samples long, stored with an explicit 16-bit block size
    private let lastFrame: [UInt8] = [0xFF, 0xF8, 0x79, 0x88, 0xE0, 0xA3, 0xB8, 0x0F, 0xBF, 0xBE]

    func test_FixedBlockSize_Frame_Number_Is_Converted_To_Sample_Number() {
        XCTAssertEqual(sampleNumber(firstFrame + [0x00, 0x2C, 0x41], nominalBlockSize: 4608), 0)
        XCTAssertEqual(sampleNumber(frame1000, nominalBlockSize: 4608), 4_608_000)
    }

    func test_FixedBlockSize_Without_Nominal_Uses_Frame_Block_Size() {
        XCTAssertEqual(sampleNumber(frame1000, nominalBlockSize: 0), 4_608_000)
    }

    func test_Shorter_Last_Frame_Is_Positioned_With_Nominal_Block_Size() {
        XCTAssertEqual(sampleNumber(lastFrame, nominalBlockSize: 4608), 2296 * 4608)
    }

    func test_VariableBlockSize_Returns_Sample_Number_Directly() {
        // 36-bit sample number (7-byte coded number), 16-bit block size, 16-bit sample rate in Hz
        let header: [UInt8] = [0xFF, 0xF9, 0x7D, 0x18, 0xFE, 0xA6, 0x87, 0x99, 0x94, 0x8C, 0xA1, 0x0F, 0x9F, 0xAC, 0x44, 0x33]
        XCTAssertEqual(sampleNumber(header, nominalBlockSize: 4608), 40_926_266_145)

        let shortHeader: [UInt8] = [0xFF, 0xF9, 0xC9, 0x18, 0xF4, 0xAD, 0x9A, 0x87, 0xF9]
        XCTAssertEqual(sampleNumber(shortHeader, nominalBlockSize: 0), 1_234_567)
    }

    func test_Header_With_Wrong_CRC_Is_Rejected() {
        var header = frame1000
        header[header.count - 1] ^= 0x01
        XCTAssertNil(sampleNumber(header, nominalBlockSize: 4608))

        var corruptedNumber = frame1000
        corruptedNumber[5] ^= 0x01
        XCTAssertNil(sampleNumber(corruptedNumber, nominalBlockSize: 4608))
    }

    func test_Data_Not_Starting_With_A_Frame_Header_Is_Rejected() {
        XCTAssertNil(sampleNumber(Array(firstFrame.dropFirst()), nominalBlockSize: 4608))
        XCTAssertNil(sampleNumber([0xFF, 0xFA] + firstFrame.dropFirst(2), nominalBlockSize: 4608))
        XCTAssertNil(sampleNumber(Array(lastFrame.dropLast()), nominalBlockSize: 4608))
    }

    private func sampleNumber(_ bytes: [UInt8], nominalBlockSize: UInt32) -> UInt64? {
        bytes.withUnsafeBytes { FlacFrameHeader.firstSampleNumber(in: $0, nominalBlockSize: nominalBlockSize) }
    }
}
