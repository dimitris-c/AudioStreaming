//
//  CustomStreamSource.swift
//  AudioPlayer
//
//  Created by Jackson Harper on 12/9/24.
//

import AVFoundation
import Foundation

import AudioStreaming

// This is a basic example of playing a custom audio stream. We generate
// a small audio data on load and then pass it off to AudioStreaming.
final class CustomStreamAudioSource: NSObject, CoreAudioStreamSource {
    weak var delegate: AudioStreamSourceDelegate?

    var underlyingQueue: DispatchQueue

    var position = 0
    var length = 0

    var audioFileHint: AudioFileTypeID {
        kAudioFileWAVEType
    }

    init(underlyingQueue: DispatchQueue) {
        self.underlyingQueue = underlyingQueue
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
        let frequency = 440.0
        let sampleRate = 44100
        let duration = 20.0

        let lpcmData = generateSineWave(frequency: frequency, sampleRate: sampleRate, duration: duration)
        let waveFile = createWavFile(using: lpcmData)

        // We enqueue this because during startup the seek call will be made, but the player
        // is not completely setup and ready to handle data yet, as its expected to be
        // generated asyncronously.
        underlyingQueue.asyncAfter(deadline: .now().advanced(by: .milliseconds(100))) {
            self.delegate?.dataAvailable(source: self, data: waveFile)
        }
    }
}

// Functions for generating some sample data

// Function to generate a sine wave as Data
func generateSineWave(frequency: Double, sampleRate: Int, duration: Double, amplitude: Double = 0.5) -> Data {
    let numberOfSamples = Int(Double(sampleRate) * duration)
    let twoPi = 2.0 * Double.pi
    var lpcmData = Data()

    for sampleIndex in 0 ..< numberOfSamples {
        let time = Double(sampleIndex) / Double(sampleRate)
        let sampleValue = amplitude * sin(twoPi * frequency * time)

        let pcmValue = Int16(sampleValue * Double(Int16.max))
        withUnsafeBytes(of: pcmValue.littleEndian) { lpcmData.append(contentsOf: $0) }
    }

    return lpcmData
}

func createWavFile(using rawData: Data) -> Data {
    let waveHeaderFormate = createWaveHeader(data: rawData) as Data
    let waveFileData = waveHeaderFormate + rawData
    return waveFileData
}

// from: https://stackoverflow.com/questions/49399823/in-ios-how-to-create-audio-file-wav-mp3-file-from-data
private func createWaveHeader(data: Data) -> NSData {
    let sampleRate: Int32 = 44100
    let chunkSize: Int32 = 36 + Int32(data.count)
    let subChunkSize: Int32 = 16
    let format: Int16 = 1
    let channels: Int16 = 2
    let bitsPerSample: Int16 = 16
    let byteRate: Int32 = sampleRate * Int32(channels * bitsPerSample / 8)
    let blockAlign: Int16 = channels * bitsPerSample / 8
    let dataSize = Int32(data.count)

    let header = NSMutableData()

    header.append([UInt8]("RIFF".utf8), length: 4)
    header.append(intToByteArray(chunkSize), length: 4)

    // WAVE
    header.append([UInt8]("WAVE".utf8), length: 4)

    // FMT
    header.append([UInt8]("fmt ".utf8), length: 4)

    header.append(intToByteArray(subChunkSize), length: 4)
    header.append(shortToByteArray(format), length: 2)
    header.append(shortToByteArray(channels), length: 2)
    header.append(intToByteArray(sampleRate), length: 4)
    header.append(intToByteArray(byteRate), length: 4)
    header.append(shortToByteArray(blockAlign), length: 2)
    header.append(shortToByteArray(bitsPerSample), length: 2)

    header.append([UInt8]("data".utf8), length: 4)
    header.append(intToByteArray(dataSize), length: 4)

    return header
}

private func intToByteArray(_ i: Int32) -> [UInt8] {
    return [
        // little endian
        UInt8(truncatingIfNeeded: i & 0xFF),
        UInt8(truncatingIfNeeded: (i >> 8) & 0xFF),
        UInt8(truncatingIfNeeded: (i >> 16) & 0xFF),
        UInt8(truncatingIfNeeded: (i >> 24) & 0xFF),
    ]
}

private func shortToByteArray(_ i: Int16) -> [UInt8] {
    return [
        // little endian
        UInt8(truncatingIfNeeded: i & 0xFF),
        UInt8(truncatingIfNeeded: (i >> 8) & 0xFF),
    ]
}
