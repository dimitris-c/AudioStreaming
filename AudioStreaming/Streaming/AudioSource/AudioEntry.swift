//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation
import AudioToolbox

public struct AudioEntryId: Equatable {
    public var id: String
}

final class EntryFramesState {
    var queued: Int = 0
    var played: Int = 0
    var lastFrameQueued: Int = -1
    
    var isAtEnd: Bool {
        return played == lastFrameQueued
    }
}

final class ProcessedPacketsState {
    var bufferSize: UInt32 = 0
    var count: UInt32 = 0
    var sizeTotal: UInt32 = 0
}

final class AudioStreamState {
    var processedDataFormat: Bool = false
    var dataOffset: UInt64 = 0
    var dataByteCount: UInt64? = nil
    var dataPacketOffset: UInt64? = nil
    var dataPacketCount: Double = 0
    var streamFormat = AudioStreamBasicDescription()
}

public class AudioEntry {
    private let estimationMinPackets = 2
    private let estimationMinPacketsPreferred = 64
    
    let lock = UnfairLock()
    
    weak var delegate: AudioStreamSourceDelegate?
    
    let id: AudioEntryId
    
    var seekTime: Float
    
    /// The sample rate from the `audioStreamFormat`
    var sampleRate: Float {
        Float(audioStreamFormat.mSampleRate)
    }
    
    var audioFileHint: AudioFileTypeID {
        source.audioFileHint
    }
    
    var audioStreamFormat = AudioStreamBasicDescription()
    
    private(set) var audioStreamState: AudioStreamState
    private(set) var framesState: EntryFramesState
    private(set) var processedPacketsState: ProcessedPacketsState
    
    private var packetDuration: Double {
        return Double(audioStreamFormat.mFramesPerPacket) / Double(sampleRate)
    }
    
    private var avaragePacketByteSize: Double {
        let packets = processedPacketsState
        guard packets.count > 0 else { return 0 }
        return Double(packets.sizeTotal / packets.count)
    }
    
    private let source: AudioStreamSource
    
    init(source: AudioStreamSource, entryId: AudioEntryId) {
        self.source = source
        self.id = entryId
        
        self.seekTime = 0
        
        self.processedPacketsState = ProcessedPacketsState()
        self.framesState = EntryFramesState()
        self.audioStreamState = AudioStreamState()
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
    
    func has(same source: AudioStreamSource) -> Bool {
        source === self.source
    }
    
    func calculatedBitrate() -> Double {
        lock.lock(); defer { lock.unlock() }
        let packets = processedPacketsState
        if packetDuration > 0 {
            if packets.count > estimationMinPacketsPreferred ||
                (audioStreamFormat.mBytesPerFrame == 0 && packets.count > estimationMinPackets) {
                return avaragePacketByteSize / packetDuration * 8
            }
        }
        return (Double(audioStreamFormat.mBytesPerFrame) * audioStreamFormat.mSampleRate) * 8
    }
    
    func progressInFrames() -> Float {
        lock.lock(); defer { lock.unlock() }
        return (seekTime + Float(audioStreamFormat.mSampleRate)) + Float(framesState.played)
    }
    
    func duration() -> Double {
        guard sampleRate > 0 else { return 0 }
        
        if let audioDataPacketOffset = audioStreamState.dataPacketOffset {
            let franesPerPacket = UInt64(audioStreamFormat.mFramesPerPacket)
            if audioDataPacketOffset > 0 && franesPerPacket > 0 {
                return Double(audioDataPacketOffset * franesPerPacket) / audioStreamFormat.mSampleRate
            }
        }
        
        let calculatedBitrate = self.calculatedBitrate()
        if calculatedBitrate < 1.0 || source.length == 0 {
            return 0
        }
        return Double(audioDataLengthBytes()) / (calculatedBitrate / 8)
    }
    
    private func audioDataLengthBytes() -> UInt {
        if let byteCount = audioStreamState.dataByteCount {
            return UInt(byteCount)
        }
        guard source.length > 0 else { return 0 }
        return UInt(source.length) - UInt(audioStreamState.dataOffset)
    }
    
}

extension AudioEntry: AudioStreamSourceDelegate {
    func dataAvailable(source: AudioStreamSource, data: Data) {
        delegate?.dataAvailable(source: source, data: data)
    }
    
    func errorOccured(source: AudioStreamSource, error: Error) {
        delegate?.errorOccured(source: source, error: error)
    }
    
    func endOfFileOccured(source: AudioStreamSource) {
        delegate?.endOfFileOccured(source: source)
    }
    
    func metadataReceived(data: [String : String]) {
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
