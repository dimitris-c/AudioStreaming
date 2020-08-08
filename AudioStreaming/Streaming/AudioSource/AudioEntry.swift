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

final public class ProcessedPacketsState {
    public var buferSize: UInt32 = 0
    public var count: UInt32 = 0
    public var sizeTotal: UInt32 = 0
}

public class AudioEntry {
    private let estimationMinPackets = 2
    private let estimationMinPacketsPreferred = 64
    
    let lock = UnfairLock()
    
    let source: AudioStreamSource
    let id: AudioEntryId
    
    var seekTime: Float
    
    var parsedHeader: Bool = false
    
    var packetCount: Double = 0
    var packetDuration: Double {
        return Double(audioStreamFormat.basicStreamDescription.mFramesPerPacket) / Double(sampleRate)
    }
    /// The sample rate from the `audioStreamBasicDescription`
    var sampleRate: Float {
        Float(audioStreamFormat.basicStreamDescription.mSampleRate)
    }
    
    var framesState: EntryFramesState
    var processedPacketsState: ProcessedPacketsState
    
    public var audioDataOffset: UInt64 = 0
    public var audioDataByteCount: UInt64?
    
    var audioStreamFormat = AVAudioFormat()
    
    private var avaragePacketByteSize: Double {
        let packets = processedPacketsState
        guard packets.count > 0 else { return 0 }
        return Double(packets.sizeTotal / packets.count)
    }
    
    init(source: AudioStreamSource, entryId: AudioEntryId) {
        self.source = source
        self.id = entryId
        
        self.seekTime = 0
        
        self.processedPacketsState = ProcessedPacketsState()
        self.framesState = EntryFramesState()
    }
    
    func reset() {
        lock.lock(); defer { lock.unlock() }
        self.framesState = EntryFramesState()
    }
    
    func calculatedBitrate() -> Double {
        let packets = processedPacketsState
        if packetDuration > 0 {
            if packets.count > estimationMinPacketsPreferred ||
                (audioStreamFormat.basicStreamDescription.mBytesPerFrame == 0 && packets.count > estimationMinPackets) {
                return avaragePacketByteSize / packetDuration * 8
            }
        }
        return (Double(audioStreamFormat.basicStreamDescription.mBytesPerFrame) * audioStreamFormat.basicStreamDescription.mSampleRate) * 8
    }
    
    func progressInFrames() -> Float {
        lock.lock(); defer { lock.unlock() }
        return (seekTime + Float(audioStreamFormat.basicStreamDescription.mSampleRate)) + Float(framesState.played)
    }
    
    func duration() -> Double {
        guard sampleRate > 0 else { return 0 }
        
        let calculatedBitrate = self.calculatedBitrate()
        if calculatedBitrate < 1.0 || source.length == 0 {
            return 0
        }
        return Double(audioDataLengthBytes()) / (calculatedBitrate / 8)
    }
    
    private func audioDataLengthBytes() -> UInt {
        if let byteCount = audioDataByteCount {
            return UInt(byteCount)
        }
        guard source.length > 0 else { return 0 }
        return UInt(source.length) - UInt(audioDataOffset)
    }
    
}

extension AudioEntry: Equatable {
    public static func == (lhs: AudioEntry, rhs: AudioEntry) -> Bool {
        lhs.id == rhs.id
    }
}

extension AudioEntry: CustomDebugStringConvertible {
    public var debugDescription: String {
        "AudioEntry: \(id), source: \(source)"
    }
}
