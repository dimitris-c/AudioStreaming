//
//  AudioEntryTests.swift
//  AudioStreamingTests
//

import AVFoundation
import XCTest
@testable import AudioStreaming

class AudioEntryTests: XCTestCase {
    func test_AudioDataLengthBytes_Is_Zero_When_DataOffset_Exceeds_Length() {
        // a live stream can report a length smaller than the parsed header offset
        let entry = audioEntry(length: 100)
        entry.audioStreamState.dataOffset = 200

        XCTAssertEqual(entry.audioDataLengthBytes(), 0)
    }

    func test_AudioDataLengthBytes_Is_Zero_When_DataOffset_Equals_Length() {
        let entry = audioEntry(length: 100)
        entry.audioStreamState.dataOffset = 100

        XCTAssertEqual(entry.audioDataLengthBytes(), 0)
    }

    func test_AudioDataLengthBytes_Subtracts_DataOffset_From_Length() {
        let entry = audioEntry(length: 1000)
        entry.audioStreamState.dataOffset = 200

        XCTAssertEqual(entry.audioDataLengthBytes(), 800)
    }

    func test_AudioDataLengthBytes_Prefers_Explicit_ByteCount() {
        let entry = audioEntry(length: 100)
        entry.audioStreamState.dataOffset = 200
        entry.audioStreamState.dataByteCount = 5000

        XCTAssertEqual(entry.audioDataLengthBytes(), 5000)
    }

    func test_Duration_Is_Zero_When_DataOffset_Exceeds_Length() {
        let entry = audioEntry(length: 100)
        entry.sampleRate = 44100
        entry.audioStreamState.bitRate = 128_000
        entry.audioStreamState.dataOffset = 200

        XCTAssertEqual(entry.duration(), 0)
    }
}

private final class FixedLengthSource: CoreAudioStreamSource {
    let position = 0
    let length: Int
    weak var delegate: AudioStreamSourceDelegate?
    let audioFileHint: AudioFileTypeID = kAudioFileMP3Type
    let underlyingQueue = DispatchQueue(label: "audio-entry-tests")

    init(length: Int) { self.length = length }

    func close() {}
    func suspend() {}
    func resume() {}
    func seek(at _: Int) {}
}

private func audioEntry(length: Int) -> AudioEntry {
    AudioEntry(source: FixedLengthSource(length: length),
               entryId: AudioEntryId(id: "entry"),
               outputAudioFormat: AVAudioFormat())
}
