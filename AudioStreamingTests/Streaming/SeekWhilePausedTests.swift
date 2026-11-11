import AVFoundation
import XCTest
@testable import AudioStreaming

final class SeekWhilePausedTests: XCTestCase {
    private func makeToneFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seek-while-paused-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(44100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0 ..< 2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = 0.01 * sin(Float(frame) * 2 * .pi * 440 / 44100)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testSeekWhilePausedLandsAfterResume() throws {
        let target = 5.0
        let url = try makeToneFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = AudioPlayer()
        defer { player.stop() }

        player.play(url: url)
        XCTAssertTrue(waitUntil(timeout: 5) { player.state == .playing && player.progress > 0.2 })

        player.pause()
        XCTAssertTrue(waitUntil(timeout: 2) { player.state == .paused })
        player.seek(to: target)
        // Stay paused long enough for the seek's own processSource pass to run and bail out.
        _ = waitUntil(timeout: 1) { false }
        player.resume()

        XCTAssertTrue(waitUntil(timeout: 3) { player.progress > target + 0.3 },
                      "progress stuck at \(player.progress), state \(player.state)")
    }
}
