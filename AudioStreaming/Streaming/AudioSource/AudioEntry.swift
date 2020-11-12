//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import AVFoundation

public struct AudioEntryId: Equatable {
    internal var unique = UUID()
    public var id: String
}

internal class AudioEntry {
    private let estimationMinPackets = 2
    private let estimationMinPacketsPreferred = 64

    let lock = UnfairLock()

    weak var delegate: AudioStreamSourceDelegate?

    let id: AudioEntryId

    /// The sample rate from the `audioStreamFormat`
    var sampleRate: Float {
        Float(audioStreamFormat.mSampleRate)
    }

    var audioFileHint: AudioFileTypeID {
        source.audioFileHint
    }

    var length: Int {
        source.length
    }

    var progress: Double {
        lock.lock(); defer { lock.unlock() }
        return seekTime + (Double(framesState.played) / outputAudioFormat.sampleRate)
    }

    var audioStreamFormat = AudioStreamBasicDescription()

    /// Hold the seek time, if a seek was requested
    var seekTime: Double

    private(set) var seekRequest: SeekRequest
    private(set) var audioStreamState: AudioStreamState
    private(set) var framesState: EntryFramesState
    private(set) var processedPacketsState: ProcessedPacketsState

    var packetDuration: Double {
        return Double(audioStreamFormat.mFramesPerPacket) / Double(sampleRate)
    }

    private var avaragePacketByteSize: Double {
        let packets = processedPacketsState
        guard !packets.isEmpty else { return 0 }
        return Double(packets.sizeTotal / packets.count)
    }

    private let source: CoreAudioStreamSource
    private let outputAudioFormat: AVAudioFormat

    init(source: CoreAudioStreamSource, entryId: AudioEntryId, outputAudioFormat: AVAudioFormat) {
        self.source = source
        self.outputAudioFormat = outputAudioFormat
        id = entryId

        seekTime = 0.0
        seekRequest = SeekRequest()
        processedPacketsState = ProcessedPacketsState()
        framesState = EntryFramesState()
        audioStreamState = AudioStreamState()
    }

    func close() {
        source.delegate = nil
        source.close()
    }

    func suspend() {
        source.suspend()
    }

    func resume() {
        source.resume()
    }

    func seek(at offset: Int) {
        source.delegate = self
        source.seek(at: offset)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        framesState = EntryFramesState()
    }

    func has(same source: CoreAudioStreamSource) -> Bool {
        source === self.source
    }

    func calculatedBitrate() -> Double {
        lock.lock(); defer { lock.unlock() }
        let packets = processedPacketsState
        if packetDuration > 0 {
            let packetsCount = packets.count
            if packetsCount > estimationMinPacketsPreferred ||
                (audioStreamFormat.mBytesPerFrame == 0 && packetsCount > estimationMinPackets)
            {
                return avaragePacketByteSize / packetDuration * 8
            }
        }
        return (Double(audioStreamFormat.mBytesPerFrame) * audioStreamFormat.mSampleRate) * 8
    }

    func progressInFrames() -> Float {
        lock.lock(); defer { lock.unlock() }
        return (Float(seekTime) * Float(audioStreamFormat.mSampleRate)) + Float(framesState.played)
    }

    func duration() -> Double {
        guard sampleRate > 0 else { return 0 }

        if let audioDataPacketOffset = audioStreamState.dataPacketOffset {
            let framesPerPacket = UInt64(audioStreamFormat.mFramesPerPacket)
            if audioDataPacketOffset > 0, framesPerPacket > 0 {
                return Double(audioDataPacketOffset * framesPerPacket) / audioStreamFormat.mSampleRate
            }
        }

        let calculatedBitrate = self.calculatedBitrate()
        if calculatedBitrate < 1.0 || source.length == 0 {
            return 0
        }
        return Double(audioDataLengthBytes()) / (calculatedBitrate / 8)
    }

    func audioDataLengthBytes() -> UInt {
        if let byteCount = audioStreamState.dataByteCount {
            return UInt(byteCount)
        }
        guard source.length > 0 else { return 0 }
        return UInt(source.length) - UInt(audioStreamState.dataOffset)
    }
}

extension AudioEntry: AudioStreamSourceDelegate {
    func dataAvailable(source: CoreAudioStreamSource, data: Data) {
        delegate?.dataAvailable(source: source, data: data)
    }

    func errorOccured(source: CoreAudioStreamSource, error: Error) {
        delegate?.errorOccured(source: source, error: error)
    }

    func endOfFileOccured(source: CoreAudioStreamSource) {
        delegate?.endOfFileOccured(source: source)
    }

    func metadataReceived(data: [String: String]) {
        delegate?.metadataReceived(data: data)
    }
}

extension AudioEntry: Equatable {
    public static func == (lhs: AudioEntry, rhs: AudioEntry) -> Bool {
        lhs.id == rhs.id
    }
}

extension AudioEntry: CustomDebugStringConvertible {
    public var debugDescription: String {
        "[AudioEntry: \(id)]"
    }
}
