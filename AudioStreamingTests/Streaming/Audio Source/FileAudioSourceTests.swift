//
//  FileAudioSourceTests.swift
//  AudioStreamingTests
//

import XCTest
@testable import AudioStreaming

class FileAudioSourceTests: XCTestCase {
    /// The default read size of `FileAudioSource`
    private let readSize = 64 * 1024

    func test_Optimized_Mp4_Decided_After_Several_Reads_Forwards_All_Bytes() throws {
        // a free atom larger than one read pushes the moov atom beyond the first read
        let ftyp = mp4Atom("ftyp", payload: ftypPayload)
        let free = mp4Atom("free", payload: pattern(count: 96 * 1024, modulo: 251))
        let moov = mp4Atom("moov", payload: pattern(count: 248, modulo: 253))
        let mdat = mp4Atom("mdat", payload: pattern(count: 32 * 1024, modulo: 241))
        let file = ftyp + free + moov + mdat
        XCTAssertGreaterThan(ftyp.count + free.count, readSize, "moov must start beyond the first read")

        let result = try readAll(file: file)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.data.count, file.count, "byte count")
        XCTAssertEqual(result.data, file)
    }

    func test_Optimized_Mp4_Decided_On_First_Read_Forwards_All_Bytes() throws {
        let ftyp = mp4Atom("ftyp", payload: ftypPayload)
        let free = mp4Atom("free", payload: pattern(count: 100, modulo: 251))
        let moov = mp4Atom("moov", payload: pattern(count: 248, modulo: 253))
        let mdat = mp4Atom("mdat", payload: pattern(count: 32 * 1024, modulo: 241))
        let file = ftyp + free + moov + mdat
        XCTAssertLessThan(file.count, readSize, "the whole file must fit in the first read")

        let result = try readAll(file: file)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.data.count, file.count, "byte count")
        XCTAssertEqual(result.data, file)
    }

    func test_Non_Optimized_Mp4_Restructure_Path_Is_Unchanged() throws {
        let ftyp = mp4Atom("ftyp", payload: ftypPayload)
        let mdat = mp4Atom("mdat", payload: pattern(count: 4 * 1024, modulo: 241))
        // no stco or co64 inside, so restructuring leaves the moov atom as it is
        let moov = mp4Atom("moov", payload: mp4Atom("udta", payload: Data(count: 8)))
        // a trailing atom keeps the synchronous moov read from ending exactly at EOF
        let free = mp4Atom("free", payload: Data(count: 8))
        let file = ftyp + mdat + moov + free

        let result = try readAll(file: file)

        // ftyp and moov first, then everything from the mdat atom onwards
        let expected = ftyp + moov + file.subdata(in: ftyp.count ..< file.count)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.data.count, expected.count, "byte count")
        XCTAssertEqual(result.data, expected)
    }

    // MARK: - Helpers

    private var ftypPayload: Data {
        Data("M4A ".utf8) + Data([0x00, 0x00, 0x02, 0x00]) + Data("M4A isom".utf8)
    }

    private func mp4Atom(_ type: String, payload: Data) -> Data {
        var atom = Data()
        withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { atom.append(contentsOf: $0) }
        atom.append(Data(type.utf8))
        atom.append(payload)
        return atom
    }

    private func pattern(count: Int, modulo: Int) -> Data {
        Data((0 ..< count).map { UInt8($0 % modulo) })
    }

    /// Plays the given bytes as a local `.m4a` file through `FileAudioSource` and records what reaches the delegate
    private func readAll(file: Data) throws -> (data: Data, error: Error?) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAudioSourceTests-\(UUID().uuidString).m4a")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = DispatchQueue(label: "file-audio-source-tests")
        let source = FileAudioSource(url: url, underlyingQueue: queue)
        let recorder = RecordingSourceDelegate(finished: expectation(description: "source finished"))
        source.delegate = recorder
        queue.async { source.seek(at: 0) }

        wait(for: [recorder.finished], timeout: 10)
        return queue.sync {
            source.close()
            return (recorder.data, recorder.error)
        }
    }
}

private final class RecordingSourceDelegate: AudioStreamSourceDelegate {
    let finished: XCTestExpectation
    var data = Data()
    var error: Error?

    init(finished: XCTestExpectation) {
        // an error can be followed by the end of the file
        finished.assertForOverFulfill = false
        self.finished = finished
    }

    func dataAvailable(source _: CoreAudioStreamSource, data: Data) {
        self.data.append(data)
    }

    func errorOccurred(source _: CoreAudioStreamSource, error: Error) {
        self.error = error
        finished.fulfill()
    }

    func endOfFileOccurred(source _: CoreAudioStreamSource) {
        finished.fulfill()
    }

    func metadataReceived(data _: [String: String]) {}
}
