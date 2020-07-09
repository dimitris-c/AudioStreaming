//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AudioToolbox

public struct AudioEntryId: Equatable {
    public var id: String
}

@objcMembers
final public class EntryFramesState: NSObject {
    public var queued: Int = 0
    public var played: Int = 0
    public var lastFrameQueued: Int = -1
}

@objcMembers
final public class ProcessedPacketsState: NSObject {
    public var buferSize: UInt32 = 0
    public var count: UInt32 = 0
    public var sizeTotal: UInt32 = 0
}

public class AudioEntry: NSObject {
    private let estimationMinPackets = 2
    private let estimationMinPacketsPreferred = 64
    
    let lock = UnfairLock()
    
    let source: AudioStreamSource
    let id: AudioEntryId
    
    var seekTime: Float
    
    var parsedHeader: Bool = false
    
    var packetCount: Double = 0
    var packetDuration: Double {
        return Double(audioStreamBasicDescription.mFramesPerPacket) / Double(sampleRate)
    }
    /// The sample rate from the `audioStreamBasicDescription`
    var sampleRate: Float {
        Float(audioStreamBasicDescription.mSampleRate)
    }
    
    @objc public var framesState: EntryFramesState
    @objc public var processedPacketsState: ProcessedPacketsState
    
    public var audioDataOffset: UInt64 = 0
    public var audioDataByteCount: UInt64?
    
    var audioStreamBasicDescription = AudioStreamBasicDescription()
    
    private let underlyingQueue: DispatchQueue
    
    private var avaragePacketByteSize: Double {
        let packets = processedPacketsState
        guard packets.count > 0 else { return 0 }
        return Double(packets.sizeTotal / packets.count)
    }
    
    init(source: AudioStreamSource, entryId: AudioEntryId, underlyingQueue: DispatchQueue) {
        self.source = source
        self.id = entryId
        
        self.seekTime = 0
        
        self.processedPacketsState = ProcessedPacketsState()
        self.framesState = EntryFramesState()
        
        self.underlyingQueue = underlyingQueue
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        self.framesState = EntryFramesState()
    }
    
    func calculatedBitrate() -> Double {
        let packets = processedPacketsState
        if packetDuration > 0 {
            if packets.count > estimationMinPacketsPreferred ||
                (audioStreamBasicDescription.mBytesPerFrame == 0 && packets.count > estimationMinPackets) {
                return avaragePacketByteSize / packetDuration * 8
            }
        }
        return (Double(audioStreamBasicDescription.mBytesPerFrame) * audioStreamBasicDescription.mSampleRate) * 8
    }
    
    func progressInFrames() -> Float {
        lock.lock(); defer { lock.unlock() }
        return (seekTime + Float(audioStreamBasicDescription.mSampleRate)) + Float(framesState.played)
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
//
//extension AudioEntry: Equatable {
//    public static func == (lhs: AudioEntry, rhs: AudioEntry) -> Bool {
//        lhs.id == rhs.id
//    }
//}
//
//extension AudioEntry: CustomStringConvertible {
//    public var description: String {
//        "AudioEntry: \(id), source: \(source)"
//    }
//}
