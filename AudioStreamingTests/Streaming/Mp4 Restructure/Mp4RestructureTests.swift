//
//  Mp4RestructureTests.swift
//  AudioStreamingTests
//

import AVFoundation
import XCTest
@testable import AudioStreaming

class Mp4RestructureTests: XCTestCase {
    // moov-at-start.m4a: 1 s AAC from afconvert, ftyp (0, 28), moov (28, 974), free (1002, 3086), mdat (4088, 3960)
    // moov-at-end.m4a: the same file with the moov moved behind the mdat and the chunk offsets adjusted,
    // ftyp (0, 28), free (28, 3086), mdat (3114, 3960), moov (7074, 974)
    private let mdatOffset = 3114
    private let moovOffset = 7074

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "m4a"))
        return try Data(contentsOf: url)
    }

    func test_Non_Optimized_Mp4_Is_Detected_From_The_Mdat_Header() throws {
        let data = try fixtureData("moov-at-end")
        let restructure = Mp4Restructure()

        // Only the start of the mdat atom has been received, as with a stream that just started
        let result = try restructure.checkIsOptimized(data: data[0 ..< mdatOffset + 100])

        XCTAssertEqual(result, .needsRestructure(moovOffset: moovOffset))
    }

    func test_Non_Optimized_Mp4_Waits_For_The_Mdat_Header() throws {
        let data = try fixtureData("moov-at-end")
        let restructure = Mp4Restructure()

        XCTAssertEqual(try restructure.checkIsOptimized(data: data[0 ..< mdatOffset + 4]), .undetermined)
        XCTAssertEqual(
            try restructure.checkIsOptimized(data: data[0 ..< mdatOffset + 8]),
            .needsRestructure(moovOffset: moovOffset)
        )
    }

    func test_Optimized_Mp4_Is_Detected_From_The_Moov_Header() throws {
        let data = try fixtureData("moov-at-start")
        let restructure = Mp4Restructure()

        XCTAssertEqual(try restructure.checkIsOptimized(data: data[0 ..< 100]), .optimized)
    }

    func test_Restructured_Mp4_Detected_Early_Is_Parsed_Without_Error() throws {
        let data = try fixtureData("moov-at-end")
        let restructure = Mp4Restructure()
        XCTAssertEqual(
            try restructure.checkIsOptimized(data: data[0 ..< mdatOffset + 100]),
            .needsRestructure(moovOffset: moovOffset)
        )

        // RemoteMp4Restructure fetches the moov from its offset and streams again from mdatOffset
        let (initialData, streamOffset) = try restructure.restructureMoov(data: Data(data[moovOffset...]))
        let restructured = initialData + data[streamOffset ..< moovOffset]

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
        let entry = AudioEntry(source: RestructureTestSource(length: restructured.count),
                               entryId: AudioEntryId(id: "entry"),
                               outputAudioFormat: outputFormat)
        playerContext.audioReadingEntry = entry

        XCTAssertEqual(processor.openFileStream(with: kAudioFileM4AType), noErr)
        defer { processor.closeFileStreamIfNeeded() }
        var offset = 0
        while offset < restructured.count {
            let chunk = restructured[offset ..< min(offset + 1024, restructured.count)]
            XCTAssertEqual(processor.parseFileStreamBytes(data: chunk), noErr, "chunk at \(offset)")
            offset += chunk.count
        }
        XCTAssertEqual(processor.flushRemainingPackets(), noErr)

        XCTAssertTrue(raisedErrors.isEmpty)
        XCTAssertEqual(entry.audioStreamState.dataByteCount, 3952)
    }
}

private final class RestructureTestSource: CoreAudioStreamSource {
    let position = 0
    let length: Int
    weak var delegate: AudioStreamSourceDelegate?
    let audioFileHint: AudioFileTypeID = kAudioFileM4AType
    let underlyingQueue = DispatchQueue(label: "mp4-restructure-tests")

    init(length: Int) { self.length = length }

    func close() {}
    func suspend() {}
    func resume() {}
    func seek(at _: Int) {}
}
