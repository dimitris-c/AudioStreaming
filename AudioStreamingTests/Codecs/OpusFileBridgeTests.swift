//
//  OpusFileBridgeTests.swift
//  AudioStreamingTests
//

import AudioCodecs
import XCTest
@testable import AudioStreaming

/// Exercises the libopusfile C bridge directly.
///
/// The bridge is pure computation over bytes — no audio hardware and no
/// `AVAudioEngine` — so unlike `OggStreamProcessor` it is fully testable in CI.
/// These tests cover the ring buffer, both callback signatures, the
/// deinterleave, and the 48 kHz output rule.
final class OpusFileBridgeTests: XCTestCase {
    /// Matches `OggStreamProcessor`'s ring buffer size.
    private let capacity = 2 * 1024 * 1024
    /// Matches the byte count `OggStreamProcessor` waits for before opening.
    private let openGate = 16384

    // MARK: - Helpers

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ogg-fixtures/\(name)", withExtension: ext),
            "missing fixture \(name).\(ext)"
        )
        return try Data(contentsOf: url)
    }

    private struct Decoded {
        var info: OFStreamInfo
        var frames: Int
        var peak: Float
        var channels: [[Float]]
        var openAttempts: Int
        var openedAfterBytes: Int
    }

    /// Feeds `data` through the bridge the way `OpusFileDecoder` does.
    ///
    /// - Parameter chunkSize: when non-nil, pushes in chunks and retries the
    ///   open once `openGate` bytes are buffered — the streaming path. When
    ///   nil, pushes everything before opening — the cached-file path.
    private func decode(_ data: Data, chunkSize: Int? = nil) throws -> Decoded {
        let stream = try XCTUnwrap(OFStreamCreate(capacity), "OFStreamCreate returned nil")
        defer { OFStreamDestroy(stream) }

        var file: OFFileRef?
        var attempts = 0
        var openedAfter = 0

        func push(_ slice: Data) {
            slice.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                OFStreamPush(stream, base, raw.count)
            }
        }

        if let chunkSize {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                push(data[offset..<end])
                offset = end
                if file == nil, OFStreamAvailableBytes(stream) >= openGate {
                    attempts += 1
                    if OFOpen(stream, &file) == 0 { openedAfter = offset }
                }
            }
            OFStreamMarkEOF(stream)
        } else {
            push(data)
            OFStreamMarkEOF(stream)
            attempts = 1
            if OFOpen(stream, &file) == 0 { openedAfter = data.count }
        }

        let of = try XCTUnwrap(file, "stream never opened after \(attempts) attempt(s)")
        defer { OFClear(of) }

        var info = OFStreamInfo()
        XCTAssertEqual(OFGetInfo(of, &info), 0, "OFGetInfo failed")

        let channelCount = Int(info.channels)
        XCTAssertGreaterThan(channelCount, 0)

        let blockFrames = 4096
        var scratch: [UnsafeMutablePointer<Float>] = (0..<channelCount).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        }
        defer { scratch.forEach { $0.deallocate() } }

        var collected = [[Float]](repeating: [], count: channelCount)
        var peak: Float = 0
        var total = 0

        while total < 48000 * 60 {  // hard stop so a bug cannot hang CI
            var pointers: [UnsafeMutablePointer<Float>?] = scratch.map { $0 }
            let got = pointers.withUnsafeMutableBufferPointer { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return Int(OFReadFloatDeinterleaved(of, base, Int32(blockFrames), Int32(channelCount)))
            }
            if got <= 0 { break }
            for channel in 0..<channelCount {
                let samples = UnsafeBufferPointer(start: scratch[channel], count: got)
                collected[channel].append(contentsOf: samples)
                for sample in samples { peak = max(peak, abs(sample)) }
            }
            total += got
        }

        return Decoded(info: info, frames: total, peak: peak, channels: collected,
                       openAttempts: attempts, openedAfterBytes: openedAfter)
    }

    /// Zero-crossing frequency estimate. On a pure sine this is exact enough to
    /// prove which channel the samples came from.
    private func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) * sampleRate / (2.0 * Double(samples.count))
    }

    // MARK: - Tests

    func testDecodesMonoTone() throws {
        let result = try decode(try fixture("opus-tone-mono-48k", "opus"))

        XCTAssertEqual(result.info.sample_rate, 48000)
        XCTAssertEqual(result.info.channels, 1)
        XCTAssertEqual(Double(result.frames) / 48000.0, 2.0, accuracy: 0.05)
        XCTAssertEqual(dominantFrequency(result.channels[0], sampleRate: 48000), 440, accuracy: 15)
    }

    /// The channels carry different tones, so a broken deinterleave shows up as
    /// the wrong frequency rather than as silence.
    func testDeinterleavesStereoChannelsIndependently() throws {
        let result = try decode(try fixture("opus-tone-stereo-48k", "opus"))

        XCTAssertEqual(result.info.channels, 2)
        XCTAssertEqual(result.channels[0].count, result.frames)
        XCTAssertEqual(result.channels[1].count, result.frames)
        XCTAssertEqual(dominantFrequency(result.channels[0], sampleRate: 48000), 440, accuracy: 15)
        XCTAssertEqual(dominantFrequency(result.channels[1], sampleRate: 48000), 660, accuracy: 15)
    }

    /// The fixtures are -18 dBFS sines; ffmpeg's own decode of them measures
    /// 0.1267 peak, so anything else means the sample scaling is wrong.
    func testSampleScalingMatchesReferenceDecoder() throws {
        let result = try decode(try fixture("opus-tone-stereo-48k", "opus"))
        XCTAssertEqual(Double(result.peak), 0.1267, accuracy: 0.002)
    }

    /// `OpusHead.input_sample_rate` records the rate of the material that was
    /// encoded, not the output rate. Opus always decodes to 48 kHz, and using
    /// the declared rate instead produces a pitch-shifted stream. This fixture
    /// declares 44100 to catch exactly that.
    func testAlwaysReports48kHzRegardlessOfDeclaredInputRate() throws {
        let result = try decode(try fixture("opus-declares-44k-input", "opus"))

        XCTAssertEqual(result.info.sample_rate, 48000)
        // Decoded at the wrong rate the tone would land near 440 * 48000/44100.
        XCTAssertEqual(dominantFrequency(result.channels[0], sampleRate: 48000), 440, accuracy: 15)
    }

    func testDecodesWhenFedInSmallChunks() throws {
        let result = try decode(try fixture("opus-tone-stereo-48k", "opus"), chunkSize: 4096)

        XCTAssertEqual(result.info.sample_rate, 48000)
        XCTAssertEqual(Double(result.frames) / 48000.0, 2.0, accuracy: 0.05)
        XCTAssertEqual(dominantFrequency(result.channels[1], sampleRate: 48000), 660, accuracy: 15)
    }

    /// Regression test for the retry path.
    ///
    /// `op_open_callbacks` consumes bytes through the read callback before it
    /// discovers the header is incomplete. Without rewinding the ring buffer on
    /// failure, every later attempt starts mid-stream and returns
    /// `OP_ENOTFORMAT` forever, so the track never plays. This fixture carries
    /// a comment header large enough that the first attempt at the open gate is
    /// guaranteed to fail — audio does not begin until byte 20230.
    func testRecoversFromFailedOpenWhenHeaderExceedsOpenGate() throws {
        let data = try fixture("opus-large-header", "opus")
        let result = try decode(data, chunkSize: 4096)

        XCTAssertGreaterThan(result.openAttempts, 1, "fixture should require more than one attempt")
        XCTAssertGreaterThan(result.openedAfterBytes, openGate)
        XCTAssertEqual(result.info.sample_rate, 48000)
        XCTAssertEqual(result.info.channels, 2)
        XCTAssertGreaterThan(result.frames, 0)
    }

    func testReportsAvailableBytesAndEOF() throws {
        let stream = try XCTUnwrap(OFStreamCreate(capacity))
        defer { OFStreamDestroy(stream) }

        XCTAssertEqual(OFStreamAvailableBytes(stream), 0)

        let bytes: [UInt8] = Array(repeating: 0xAB, count: 1024)
        bytes.withUnsafeBufferPointer { OFStreamPush(stream, $0.baseAddress!, $0.count) }
        XCTAssertEqual(OFStreamAvailableBytes(stream), 1024)

        OFStreamMarkEOF(stream)
        XCTAssertEqual(OFStreamAvailableBytes(stream), 1024, "EOF must not discard buffered bytes")
    }

    func testOpenRejectsNonOpusData() throws {
        let stream = try XCTUnwrap(OFStreamCreate(capacity))
        defer { OFStreamDestroy(stream) }

        let junk = [UInt8](repeating: 0x5A, count: 32768)
        junk.withUnsafeBufferPointer { OFStreamPush(stream, $0.baseAddress!, $0.count) }
        OFStreamMarkEOF(stream)

        var file: OFFileRef?
        XCTAssertLessThan(OFOpen(stream, &file), 0)
        XCTAssertNil(file)
    }

    /// A Vorbis stream must not open as Opus — that mismatch is the bug the
    /// sniffer exists to prevent, and the bridge is the last line of defence.
    func testOpenRejectsVorbisStream() throws {
        let data = try fixture("vorbis-tone-stereo-44k", "ogg")
        let stream = try XCTUnwrap(OFStreamCreate(capacity))
        defer { OFStreamDestroy(stream) }

        data.withUnsafeBytes { raw in
            OFStreamPush(stream, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count)
        }
        OFStreamMarkEOF(stream)

        var file: OFFileRef?
        XCTAssertLessThan(OFOpen(stream, &file), 0)
        XCTAssertNil(file)
    }
}
