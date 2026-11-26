//
//  Mp4ProbeForwardPlaybackTests.swift
//  AudioStreamingTests
//

import XCTest
@testable import AudioStreaming

final class Mp4ProbeForwardPlaybackTests: XCTestCase {
    /// The default read size of `FileAudioSource`
    private let readSize = 64 * 1024

    func test_Local_Mp4_Optimized_After_Several_Reads_Plays_To_End() throws {
        // A 2 s, 440 Hz, 44.1 kHz mono AAC-LC tone (ffmpeg, 64 kbit/s, -movflags +faststart), with a
        // 72 KiB top-level free atom inserted before moov and the stco chunk offsets shifted to match
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "faststart-free-before-moov", withExtension: "m4a"))
        let data = try Data(contentsOf: fixtureURL)
        // the fixture is only recognised as optimized once more than the first read is buffered
        XCTAssertEqual(try Mp4Restructure().checkIsOptimized(data: Data(data.prefix(readSize))), .undetermined)
        XCTAssertEqual(try Mp4Restructure().checkIsOptimized(data: data), .optimized)

        let recorder = Mp4PlaybackRecorder()
        let finished = expectation(description: "audioPlayerDidFinishPlaying")
        recorder.onFinish = { finished.fulfill() }

        let player = AudioPlayer()
        player.delegate = recorder
        // AudioPlayer.init creates its output unit asynchronously
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        var progressSamples: [Double] = []
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            progressSamples.append(player.progress)
        }
        player.play(url: fixtureURL)
        // a short wait, so that a stalled player fails on the assertions below instead of a timeout
        let waitResult = XCTWaiter().wait(for: [finished], timeout: 8)
        sampler.invalidate()
        recorder.onFinish = nil
        player.stop()

        let positiveProgress = progressSamples.filter { $0 > 0 }
        let observed = "waiter=\(waitResult.rawValue) events=\(recorder.events) maxProgress=\(progressSamples.max() ?? 0)"

        XCTAssertEqual(waitResult, .completed, "playback did not finish; \(observed)")
        XCTAssertTrue(recorder.started, "playback did not start; \(observed)")
        XCTAssertTrue(recorder.errors.isEmpty, "unexpected errors: \(recorder.errors)")
        XCTAssertGreaterThan(positiveProgress.last ?? 0, positiveProgress.first ?? 0, "progress did not grow; \(observed)")
        XCTAssertEqual(recorder.finishReason, .eof, "unexpected stop reason; \(observed)")
        XCTAssertGreaterThan(recorder.finishProgress ?? 0, 1.8, "did not play the whole 2 s; \(observed)")
    }
}

private final class Mp4PlaybackRecorder: AudioPlayerDelegate {
    private let start = Date()
    private(set) var events: [String] = []
    private(set) var started = false
    private(set) var errors: [String] = []
    private(set) var finishProgress: Double?
    private(set) var finishReason: AudioPlayerStopReason?
    var onFinish: (() -> Void)?

    private func log(_ text: String) {
        events.append(String(format: "+%.2fs ", Date().timeIntervalSince(start)) + text)
    }

    func audioPlayerDidStartPlaying(player _: AudioPlayer, with _: AudioEntryId) {
        started = true
        log("didStartPlaying")
    }

    func audioPlayerDidFinishBuffering(player _: AudioPlayer, with _: AudioEntryId) {
        log("didFinishBuffering")
    }

    func audioPlayerStateChanged(player _: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        log("stateChanged \(previous) -> \(newState)")
    }

    func audioPlayerDidFinishPlaying(player _: AudioPlayer,
                                     entryId _: AudioEntryId,
                                     stopReason: AudioPlayerStopReason,
                                     progress: Double,
                                     duration: Double)
    {
        log(String(format: "didFinishPlaying \(stopReason) progress=%.3f duration=%.3f", progress, duration))
        guard finishProgress == nil else { return }
        finishProgress = progress
        finishReason = stopReason
        onFinish?()
    }

    func audioPlayerUnexpectedError(player _: AudioPlayer, error: AudioPlayerError) {
        errors.append("\(error)")
        log("unexpectedError \(error)")
    }

    func audioPlayerDidCancel(player _: AudioPlayer, queuedItems _: [AudioEntryId]) {
        log("didCancel")
    }

    func audioPlayerDidReadMetadata(player _: AudioPlayer, metadata _: [String: String]) {
        log("didReadMetadata")
    }
}
