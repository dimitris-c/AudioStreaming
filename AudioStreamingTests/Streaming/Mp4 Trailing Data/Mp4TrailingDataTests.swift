//
//  Mp4TrailingDataTests.swift
//  AudioStreamingTests
//

import AVFoundation
import XCTest
@testable import AudioStreaming

class Mp4TrailingDataTests: XCTestCase {
    func test_Offset_Inside_Audio_Data_Is_Not_Past() {
        XCTAssertFalse(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 900, dataOffset: 100, dataByteCount: 1000))
    }

    func test_Offset_At_End_Of_Audio_Data_Is_Not_Past() {
        XCTAssertFalse(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 1100, dataOffset: 100, dataByteCount: 1000))
    }

    func test_Offset_After_End_Of_Audio_Data_Is_Past() {
        XCTAssertTrue(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 1101, dataOffset: 100, dataByteCount: 1000))
    }

    func test_Unknown_Audio_Data_Is_Never_Past() {
        XCTAssertFalse(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 5000, dataOffset: 100, dataByteCount: nil))
        XCTAssertFalse(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 5000, dataOffset: 100, dataByteCount: 0))
        XCTAssertFalse(AudioFileStreamProcessor.isPastMp4AudioData(byteOffset: 5000, dataOffset: 0, dataByteCount: 1000))
    }

    func test_Trailing_Zero_Padding_After_Mdat_Is_Parsed_Without_Error() throws {
        // AAC m4a with 4096 zero bytes after the mdat atom, which AudioFileStream rejects as an invalid file
        let url = try XCTUnwrap(Bundle.module.url(forResource: "trailing-zero-padding", withExtension: "m4a"))
        let data = try Data(contentsOf: url)

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: true)!
        let playerContext = AudioPlayerContext()
        let rendererContext = AudioRendererContext(configuration: .default, outputAudioFormat: outputFormat)
        defer { rendererContext.clean() }
        let processor = AudioFileStreamProcessor(playerContext: playerContext,
                                                 rendererContext: rendererContext,
                                                 outputAudioFormat: outputFormat.basicStreamDescription)
        var raisedErrors: [AudioPlayerError] = []
        processor.fileStreamCallback = { effect in
            if case let .raiseError(error) = effect { raisedErrors.append(error) }
        }
        let entry = AudioEntry(source: Mp4Source(length: data.count),
                               entryId: AudioEntryId(id: "entry"),
                               outputAudioFormat: outputFormat)
        playerContext.audioReadingEntry = entry

        XCTAssertEqual(processor.openFileStream(with: kAudioFileM4AType), noErr)
        defer { processor.closeFileStreamIfNeeded() }
        var offset = 0
        while offset < data.count {
            let chunk = data[offset ..< min(offset + 1024, data.count)]
            XCTAssertEqual(processor.parseFileStreamBytes(data: chunk), noErr, "chunk at \(offset)")
            offset += chunk.count
        }
        XCTAssertEqual(processor.flushRemainingPackets(), noErr)

        XCTAssertTrue(raisedErrors.isEmpty)
        XCTAssertEqual(entry.audioStreamState.dataOffset, 4096)
        XCTAssertEqual(entry.audioStreamState.dataByteCount, 1183)
    }
}

private final class Mp4Source: CoreAudioStreamSource {
    let position = 0
    let length: Int
    weak var delegate: AudioStreamSourceDelegate?
    let audioFileHint: AudioFileTypeID = kAudioFileM4AType
    let underlyingQueue = DispatchQueue(label: "mp4-trailing-data-tests")

    init(length: Int) { self.length = length }

    func close() {}
    func suspend() {}
    func resume() {}
    func seek(at _: Int) {}
}
