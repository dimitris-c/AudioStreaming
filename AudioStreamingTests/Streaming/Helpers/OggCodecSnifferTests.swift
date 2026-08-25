//
//  OggCodecSnifferTests.swift
//  AudioStreamingTests
//

import XCTest
@testable import AudioStreaming

/// `OggCodecSniffer` decides which decoder an `audio/ogg` stream is routed to,
/// so a mistake here silently hands Opus to libvorbisfile (or the reverse).
/// It is pure byte arithmetic, which makes it cheap to cover exhaustively.
final class OggCodecSnifferTests: XCTestCase {
    private let opusHead = Array("OpusHead".utf8) + [UInt8](repeating: 0, count: 11)
    private let vorbisIdentification = [UInt8(0x01)] + Array("vorbis".utf8) + [UInt8](repeating: 0, count: 23)

    /// Builds an Ogg page header (RFC 3533 §6) with the given lacing table.
    private func page(segments: [UInt8], payload: [UInt8], capture: String = "OggS") -> [UInt8] {
        var bytes = Array(capture.utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 22))  // through byte 25
        bytes.append(UInt8(segments.count))                          // byte 26
        bytes.append(contentsOf: segments)                           // segment table
        bytes.append(contentsOf: payload)
        return bytes
    }

    private func fixtureBytes(_ name: String, _ ext: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ogg-fixtures/\(name)", withExtension: ext))
        return [UInt8](try Data(contentsOf: url))
    }

    // MARK: - Real files

    func testIdentifiesRealOpusFile() throws {
        XCTAssertEqual(OggCodecSniffer.sniff(try fixtureBytes("opus-tone-stereo-48k", "opus")), .opus)
    }

    func testIdentifiesRealVorbisFile() throws {
        XCTAssertEqual(OggCodecSniffer.sniff(try fixtureBytes("vorbis-tone-stereo-44k", "ogg")), .vorbis)
    }

    /// The whole point of the sniffer: these two are both served as `audio/ogg`
    /// and must not be confused with one another.
    func testDistinguishesOpusFromVorbis() throws {
        let opus = try fixtureBytes("opus-tone-stereo-48k", "opus")
        let vorbis = try fixtureBytes("vorbis-tone-stereo-44k", "ogg")
        XCTAssertEqual(OggCodecSniffer.sniff(opus), .opus)
        XCTAssertEqual(OggCodecSniffer.sniff(vorbis), .vorbis)
    }

    // MARK: - Synthetic pages

    func testSingleSegmentPages() {
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [19], payload: opusHead)), .opus)
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [30], payload: vorbisIdentification)), .vorbis)
    }

    /// The reason the payload offset is computed rather than hardcoded: every
    /// lacing entry shifts the codec magic by one more byte.
    func testMultiSegmentPagesShiftThePayloadOffset() {
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [255, 255, 255, 19], payload: opusHead)), .opus)
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [255, 30], payload: vorbisIdentification)), .vorbis)
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [UInt8](repeating: 1, count: 255), payload: opusHead)), .opus)
    }

    func testMaxHeaderLengthCoversTheLargestPossibleFirstPage() {
        // 27-byte header + 255-entry lacing table + 8-byte codec magic.
        XCTAssertEqual(OggCodecSniffer.maxHeaderLength, 290)
        let worstCase = page(segments: [UInt8](repeating: 1, count: 255), payload: opusHead)
        XCTAssertLessThanOrEqual(OggCodecSniffer.maxHeaderLength, worstCase.count)
    }

    // MARK: - Codecs we do not decode

    func testUnsupportedOggCodecsAreReportedNotGuessed() {
        let flac = [UInt8(0x7F)] + Array("FLAC".utf8) + [UInt8](repeating: 0, count: 20)
        let speex = Array("Speex   ".utf8) + [UInt8](repeating: 0, count: 20)
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [1], payload: flac)), .unsupported)
        XCTAssertEqual(OggCodecSniffer.sniff(page(segments: [1], payload: speex)), .unsupported)
    }

    func testNonOggDataIsUnsupported() {
        let mp3 = Array("ID3\u{4}".utf8) + [UInt8](repeating: 0, count: 40)
        XCTAssertEqual(OggCodecSniffer.sniff(mp3), .unsupported)
    }

    // MARK: - Partial input

    /// `nil` means "feed me more" and must never be confused with a decision;
    /// answering early would route the stream to the wrong decoder.
    func testTruncatedInputAsksForMoreBytes() {
        XCTAssertNil(OggCodecSniffer.sniff([UInt8]()))
        XCTAssertNil(OggCodecSniffer.sniff([UInt8](repeating: 0, count: 26)))
        XCTAssertNil(OggCodecSniffer.sniff(page(segments: [19], payload: [])))

        let full = page(segments: [255, 255, 255, 19], payload: opusHead)
        XCTAssertNil(OggCodecSniffer.sniff(Array(full.prefix(29))), "truncated inside the segment table")
        XCTAssertNil(OggCodecSniffer.sniff(Array(full.prefix(27 + 4 + 7))), "one byte short of the magic")
    }

    func testDataOverloadMatchesArrayOverload() {
        let bytes = page(segments: [19], payload: opusHead)
        XCTAssertEqual(OggCodecSniffer.sniff(Data(bytes)), OggCodecSniffer.sniff(bytes))
        XCTAssertNil(OggCodecSniffer.sniff(Data()))
    }

    /// The sniffer only ever inspects the head of the stream, so handing it a
    /// whole file must be no different from handing it the first page.
    func testOnlyTheHeadOfTheStreamMatters() throws {
        let whole = try fixtureBytes("opus-tone-stereo-48k", "opus")
        let head = Array(whole.prefix(OggCodecSniffer.maxHeaderLength))
        XCTAssertEqual(OggCodecSniffer.sniff(whole), OggCodecSniffer.sniff(head))
    }
}
