//
//  GaplessTrimTests.swift
//  AudioStreamingTests
//

import AudioToolbox
import XCTest
@testable import AudioStreaming

class GaplessTrimTests: XCTestCase {
    private func range(_ start: Int, _ count: Int, priming: Int = 2112, valid: Int = 10000, ratio: Double = 1) -> (leading: Int, kept: Int) {
        GaplessTrim.keptRange(decodedStart: start, framesCount: count, primingFrames: priming, validFrames: valid, ratio: ratio)
    }

    func test_Chunk_Inside_Priming_Is_Dropped() {
        let r = range(0, 1024)
        XCTAssertEqual(r.kept, 0)
    }

    func test_Chunk_Straddling_Priming_Drops_Leading_Frames() {
        let r = range(2048, 1024)
        XCTAssertEqual(r.leading, 64)
        XCTAssertEqual(r.kept, 960)
    }

    func test_Chunk_Inside_Valid_Range_Is_Kept() {
        let r = range(4096, 1024)
        XCTAssertEqual(r.leading, 0)
        XCTAssertEqual(r.kept, 1024)
    }

    func test_Chunk_Straddling_End_Drops_Trailing_Frames() {
        // valid range ends at 2112 + 10000 = 12112
        let r = range(11776, 1024)
        XCTAssertEqual(r.leading, 0)
        XCTAssertEqual(r.kept, 336)
    }

    func test_Chunk_After_Valid_Range_Is_Dropped() {
        XCTAssertEqual(range(12112, 1024).kept, 0)
    }

    func test_Chunk_Containing_Whole_Valid_Range() {
        let r = range(0, 20000, priming: 100, valid: 500)
        XCTAssertEqual(r.leading, 100)
        XCTAssertEqual(r.kept, 500)
    }

    func test_Kept_Frames_Over_Chunks_Equal_Valid_Frames() {
        var decoded = 0
        var total = 0
        for count in [1024, 1024, 777, 4096, 1, 9000, 1024] {
            total += range(decoded, count).kept
            decoded += count
        }
        XCTAssertEqual(total, 10000)
    }

    func test_Ratio_Scales_Priming_And_Valid() {
        let r = range(0, 20000, priming: 1000, valid: 4000, ratio: 48000.0 / 44100.0)
        XCTAssertEqual(r.leading, 1088)
        XCTAssertEqual(r.kept, 4354)
    }

    func test_Kept_Frames_Over_Chunks_Match_Rounded_End_With_Ratio() {
        let ratio = 48000.0 / 44100.0
        var decoded = 0
        var total = 0
        for count in [1000, 1024, 777, 4096, 1, 9000, 1024] {
            let r = range(decoded, count, priming: 1105, valid: 7003, ratio: ratio)
            total += r.kept
            decoded += count
        }
        // keepFrom = round(1105 * ratio), keepTo = round(8108 * ratio)
        XCTAssertEqual(total, Int((8108 * ratio).rounded()) - Int((1105 * ratio).rounded()))
    }

    func test_Trailing_Drop_Is_Limited_By_Unplayed_And_Used_Frames() {
        XCTAssertEqual(GaplessTrim.trailingFramesToDrop(remainderFrames: 500, ratio: 1, notPlayedFrames: 10000, usedFrames: 10000), 500)
        XCTAssertEqual(GaplessTrim.trailingFramesToDrop(remainderFrames: 500, ratio: 1, notPlayedFrames: 200, usedFrames: 10000), 200)
        XCTAssertEqual(GaplessTrim.trailingFramesToDrop(remainderFrames: 500, ratio: 1, notPlayedFrames: 10000, usedFrames: 100), 100)
        XCTAssertEqual(GaplessTrim.trailingFramesToDrop(remainderFrames: 500, ratio: 1, notPlayedFrames: -5, usedFrames: 100), 0)
    }

    func test_Trailing_Drop_Scales_With_Ratio() {
        XCTAssertEqual(GaplessTrim.trailingFramesToDrop(remainderFrames: 1000, ratio: 2, notPlayedFrames: 5000, usedFrames: 5000), 2000)
    }

    func test_Assumed_Priming_For_Mp3_Without_Packet_Table_Info() {
        XCTAssertEqual(GaplessTrim.assumedPrimingFrames(formatID: kAudioFormatMPEGLayer3, hasPacketTableInfo: false), 576)
    }

    func test_No_Assumed_Priming_For_Mp3_With_Packet_Table_Info() {
        XCTAssertEqual(GaplessTrim.assumedPrimingFrames(formatID: kAudioFormatMPEGLayer3, hasPacketTableInfo: true), 0)
    }

    func test_No_Assumed_Priming_For_Other_Formats() {
        XCTAssertEqual(GaplessTrim.assumedPrimingFrames(formatID: kAudioFormatMPEG4AAC, hasPacketTableInfo: false), 0)
    }

    func test_Trailing_Silent_Frames_Counts_Until_Signal() {
        let samples: [Float] = [0.5, 0.4, 0, 0.0005, 0, 0] // oldest to newest
        let count = GaplessTrim.trailingSilentFrames(limit: 100, referenceFrames: 0) { samples[samples.count - 1 - $0] }
        XCTAssertEqual(count, 4)
    }

    func test_Trailing_Silent_Frames_Is_Limited() {
        let count = GaplessTrim.trailingSilentFrames(limit: 3, referenceFrames: 0) { _ in 0 }
        XCTAssertEqual(count, 3)
    }

    func test_Trailing_Silent_Frames_Zero_For_Signal_At_End() {
        let count = GaplessTrim.trailingSilentFrames(limit: 100, referenceFrames: 0) { _ in 0.2 }
        XCTAssertEqual(count, 0)
    }

    func test_Trailing_Decay_Is_Dropped_Relative_To_Loud_Music() {
        // loud music (0.5), then a decaying tail below 2 % of it
        let samples: [Float] = Array(repeating: 0.5, count: 50) + [0.008, 0.006, 0.004, 0.003]
        let count = GaplessTrim.trailingSilentFrames(limit: 4, referenceFrames: 40) { samples[samples.count - 1 - $0] }
        XCTAssertEqual(count, 4)
    }

    func test_Trailing_Quiet_Music_Is_Kept() {
        // quiet music (0.02): 2 % of it is below the minimum, so only really silent frames are dropped
        let samples: [Float] = Array(repeating: 0.02, count: 50) + [0.004, 0.004]
        let count = GaplessTrim.trailingSilentFrames(limit: 2, referenceFrames: 40) { samples[samples.count - 1 - $0] }
        XCTAssertEqual(count, 0)
    }

    func test_Ringing_After_An_Abrupt_Music_End_Is_Dropped() {
        // music at 0.4, then the ringing of the codec at about 0.04 and a noise floor, as measured on a live stream
        let tail: [Float] = [0.044, 0.010, 0.041, 0.010, 0.036, 0.024, 0.006, 0.004]
        let samples: [Float] = Array(repeating: 0.4, count: 50) + tail
        let count = GaplessTrim.trailingSilentFrames(limit: 20, referenceFrames: 30) { samples[samples.count - 1 - $0] }
        XCTAssertEqual(count, tail.count)
    }
}
