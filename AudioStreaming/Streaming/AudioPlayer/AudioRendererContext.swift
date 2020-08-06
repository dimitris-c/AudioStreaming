//
//  Created by Dimitrios Chatzieleftheriou on 10/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import CoreAudio
import AVFoundation

internal var maxFramesPerSlice: AVAudioFrameCount = 8192

final class AudioRendererContext: NSObject {
    var fileFormat: String = ""

    public let lock = UnfairLock()
    
    let readBufferSize: Int
    let readBuffer: UnsafeMutablePointer<UInt8>
    
    let bufferContext: BufferContext

    let seekRequest: SeekRequest
    
    var audioBuffer: AudioBuffer
    var inAudioBufferList: UnsafeMutablePointer<AudioBufferList>
    var outAudioBufferList: UnsafeMutablePointer<AudioBufferList>
    
    let packetsSemaphore = DispatchSemaphore(value: 1)
    
    var discontinuous: Bool = false
    
    let framesRequestToStartPlaying: UInt32
    let framesRequiredAfterRebuffering: UInt32
    
    var waiting: Bool = false
    
    let configuration: AudioPlayerConfiguration
    init(configuration: AudioPlayerConfiguration, audioFormat: AVAudioFormat) {
        self.configuration = configuration
        self.readBufferSize = configuration.readBufferSize
        self.readBuffer = UnsafeMutablePointer<UInt8>.uint8pointer(of: readBufferSize)
        self.seekRequest = SeekRequest()
        
        let canonicalStream = audioFormat.basicStreamDescription
        
        self.framesRequestToStartPlaying = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlaying)
        self.framesRequiredAfterRebuffering = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlayingAfterBufferUnderun)
        
        let dataByteSize = Int(canonicalStream.mSampleRate * configuration.bufferSizeInSeconds) * Int(canonicalStream.mBytesPerFrame)
        inAudioBufferList = allocateBufferList(dataByteSize: dataByteSize)
        outAudioBufferList = allocateBufferList(dataByteSize: dataByteSize)
        
        audioBuffer = outAudioBufferList[0].mBuffers
        
        let bufferTotalFrameCount = UInt32(dataByteSize) / canonicalStream.mBytesPerFrame
        
        self.bufferContext = BufferContext(sizeInBytes: canonicalStream.mBytesPerFrame,
                                           totalFrameCount: bufferTotalFrameCount)

    }
    
    /// Deallocates buffer resources
    public func clean() {
        readBuffer.deallocate()
        inAudioBufferList.deallocate()
        outAudioBufferList.deallocate()
        audioBuffer.mData?.deallocate()
    }
    
    /// Resets the `BufferContext`
    public func resetBuffers() {
        lock.lock(); defer { lock.unlock() }
        bufferContext.reset()
    }
    
}

/// Allocates a buffer list
///
/// - parameter dataByteSize: An `Int` value indicating the size that the buffer will hold
/// - Returns: An `UnsafeMutablePointer<AudioBufferList>` object
private func allocateBufferList(dataByteSize: Int) -> UnsafeMutablePointer<AudioBufferList> {
    let _bufferList = AudioBufferList.allocate(maximumBuffers: 1)
    
    _bufferList[0].mDataByteSize = UInt32(dataByteSize)
    let alingment = MemoryLayout<UInt8>.alignment
    let mData = UnsafeMutableRawPointer.allocate(byteCount: Int(dataByteSize), alignment: alingment)
    _bufferList[0].mData = mData
    _bufferList[0].mNumberChannels = 2
    
    return _bufferList.unsafeMutablePointer
}

final public class SeekRequest {
    var requested: Bool = false
    var time: Int = 0
}
