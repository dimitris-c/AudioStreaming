//
//  PlayerStreamTest.swift
//  AudioStreaming
//
//  Created by Jackson Harper on 25/10/24.
//  Copyright © 2024 Decimal. All rights reserved.
//


import AVFoundation
import Foundation
import XCTest

@testable import AudioStreaming

class PlayerSteamTest: XCTestCase {
    func testPlayerQueueEntriesInitsEmpty() {
        let queue = PlayerQueueEntries()
        
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.count(for: .buffering), 0)
        XCTAssertEqual(queue.count(for: .upcoming), 0)
    }
    
    func testPlayerStreamWAVData() {
        let path = Bundle(for: Self.self).path(forResource: "short-counting-to-five", ofType: "wav")!
        let data1 = (try? Data(NSData(contentsOfFile: path)))!
        let data2 = (try? Data(NSData(contentsOfFile: path)))!
        let data3 = (try? Data(NSData(contentsOfFile: path)))!

        let expectation = XCTestExpectation(description: "Wait audio to be queued")

        let player = AudioPlayer(configuration: .default)
        let stream = TestStreamAudioSource(player: player, type: kAudioFileWAVEType, buffers: [data1, data2, data3]) {
            expectation.fulfill()
        }
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false
        )!

        player.play(source: stream, entryId: UUID().uuidString, format: audioFormat)

        wait(for: [expectation], timeout: 5)
        XCTAssertGreaterThan(player.duration, 3)
    }
    
    func testPlayerStreamMP3Data() {
        let path = Bundle(for: Self.self).path(forResource: "short-counting-to-five", ofType: "mp3")!
        let data1 = (try? Data(NSData(contentsOfFile: path)))!
        let data2 = (try? Data(NSData(contentsOfFile: path)))!
        let data3 = (try? Data(NSData(contentsOfFile: path)))!

        let expectation = XCTestExpectation(description: "Wait audio to be queued")

        let player = AudioPlayer(configuration: .default)
        let stream = TestStreamAudioSource(player: player, type: kAudioFileMP3Type, buffers: [data1, data2, data3]) {
            expectation.fulfill()
        }
        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false
        )!

        player.play(source: stream, entryId: UUID().uuidString, format: audioFormat)

        wait(for: [expectation], timeout: 5)
        XCTAssertGreaterThan(player.duration, 3)
    }
}


final class TestStreamAudioSource: NSObject, CoreAudioStreamSource {
    weak var player: AudioPlayer?
    weak var delegate: AudioStreamSourceDelegate?

    var underlyingQueue: DispatchQueue

    var position = 0
    var length = 0

    let buffers: [Data]
    let onReady: () -> Void
    let audioFileHint: AudioFileTypeID

    init(player: AudioPlayer, type: AudioFileTypeID, buffers: [Data], onReady: @escaping () -> Void) {
        self.player = player
        self.audioFileHint = type
        self.buffers = buffers
        self.onReady = onReady
        self.underlyingQueue = player.sourceQueue
    }

    // no-op
    func close() {}

    // no-op
    func suspend() {}

    func resume() {}

    func seek(at _: Int) {
        // The streaming process is started by a seek(0) call from AudioStreaming
        generateData()
    }

    private func generateData() {
        underlyingQueue.asyncAfter(deadline: .now().advanced(by: .milliseconds(100))) {
            for buffer in self.buffers {
                self.length += buffer.count
                self.delegate?.dataAvailable(source: self, data: buffer)
            }
            DispatchQueue.main.async {
                self.onReady()
            }
        }
    }
}
