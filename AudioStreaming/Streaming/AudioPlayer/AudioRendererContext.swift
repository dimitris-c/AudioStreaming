//
//  Created by Dimitrios Chatzieleftheriou on 10/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import CoreAudio
import AVFoundation

final class AudioRendererContext: NSObject {
    var fileFormat: String = ""
    var maxFramesPerBuffer: Int = 0

    public let lock = UnfairLock()
    
    let readBufferSize: Int
    var readBuffer: UnsafeMutablePointer<UInt8>
    
    var bufferFrameSizeInBytes: UInt32 = 0
    var bufferTotalFrameCount: UInt32 = 0
    var bufferFramesStartIndex: UInt32 = 0
    var bufferUsedFrameCount: UInt32 = 0
    
    var seekRequest: SeekRequest
    
    var audioBuffer: AudioBuffer
    var inAudioBufferList: UnsafeMutablePointer<AudioBufferList>
    var outAudioBufferList: UnsafeMutablePointer<AudioBufferList>
    
    var discontinuous: Bool = false
    
    let framesRequestToStartPlaying: UInt32
    let framesRequiredAfterRebuffering: UInt32
    
    var waiting: Bool = false
    
    let configuration: AudioPlayerConfiguration
    init(configuration: AudioPlayerConfiguration) {
        self.configuration = configuration
        self.readBufferSize = configuration.readBufferSize
        self.readBuffer = UnsafeMutablePointer<UInt8>.uint8pointer(of: readBufferSize)
        self.seekRequest = SeekRequest()
        
        let canonicalStream = UnitDescriptions.canonicalAudioStream
        
        self.framesRequestToStartPlaying = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlaying)
        self.framesRequiredAfterRebuffering = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlayingAfterBufferUnderun)
        
        let dataByteSize = Int(canonicalStream.mSampleRate * configuration.bufferSizeInSeconds) * Int(canonicalStream.mBytesPerFrame)
        inAudioBufferList = allocateBufferList(dataByteSize: dataByteSize)
        outAudioBufferList = allocateBufferList(dataByteSize: dataByteSize)
        
        audioBuffer = outAudioBufferList[0].mBuffers
        
        let bufferTotalFrameCount = UInt32(dataByteSize) / canonicalStream.mBytesPerFrame
        self.bufferTotalFrameCount = bufferTotalFrameCount
        self.bufferFrameSizeInBytes = canonicalStream.mBytesPerFrame

    }
    
    public func clean() {
        readBuffer.deallocate()
        inAudioBufferList.deallocate()
        outAudioBufferList.deallocate()
        audioBuffer.mData?.deallocate()
    }
    
    public func resetBuffers() {
        lock.lock(); defer { lock.unlock() }
        bufferFramesStartIndex = 0
        bufferUsedFrameCount = 0
    }
    
}

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
