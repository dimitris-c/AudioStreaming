//
//  Created by Dimitrios Chatzieleftheriou on 10/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation
import CoreAudio

var maxFramesPerSlice: AVAudioFrameCount = 8192

final class AudioRendererContext {
    let waiting = Atomic<Bool>(false)

    let lock = UnfairLock()

    let bufferContext: BufferContext

    let audioBuffer: AudioBuffer
    let inOutAudioBufferList: UnsafeMutablePointer<AudioBufferList>

    let packetsSemaphore = DispatchSemaphore(value: 0)

    let framesRequiredToStartPlaying: UInt32
    let framesRequiredAfterRebuffering: UInt32
    let framesRequiredForDataAfterSeekPlaying: UInt32

    let waitingForDataAfterSeekFrameCount = Atomic<Int32>(0)

    private let configuration: AudioPlayerConfiguration

    init(configuration: AudioPlayerConfiguration, outputAudioFormat: AVAudioFormat) {
        self.configuration = configuration

        let canonicalStream = outputAudioFormat.basicStreamDescription

        framesRequiredToStartPlaying = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlaying)
        framesRequiredAfterRebuffering = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.secondsRequiredToStartPlayingAfterBufferUnderrun)
        framesRequiredForDataAfterSeekPlaying = UInt32(canonicalStream.mSampleRate) * UInt32(configuration.gracePeriodAfterSeekInSeconds)

        let dataByteSize = Int(canonicalStream.mSampleRate * configuration.bufferSizeInSeconds) * Int(canonicalStream.mBytesPerFrame)
        inOutAudioBufferList = allocateBufferList(dataByteSize: dataByteSize)

        audioBuffer = inOutAudioBufferList[0].mBuffers

        let bufferTotalFrameCount = UInt32(dataByteSize) / canonicalStream.mBytesPerFrame

        bufferContext = BufferContext(sizeInBytes: canonicalStream.mBytesPerFrame,
                                      totalFrameCount: bufferTotalFrameCount)
    }

    func fillSilenceAudioBuffer() {
        let count = Int(bufferContext.totalFrameCount * bufferContext.sizeInBytes)
        memset(audioBuffer.mData, 0, count)
    }

    /// Deallocates buffer resources
    func clean() {
        inOutAudioBufferList.deallocate()
        audioBuffer.mData?.deallocate()
    }

    /// Resets the `BufferContext`
    func resetBuffers() {
        lock.lock(); defer { lock.unlock() }
        bufferContext.frameStartIndex = 0
        bufferContext.frameUsedCount = 0
    }
}

/// Allocates a buffer list
///
/// - parameter dataByteSize: An `Int` value indicating the size that the buffer will hold
/// - Returns: An `UnsafeMutablePointer<AudioBufferList>` object
private func allocateBufferList(dataByteSize: Int) -> UnsafeMutablePointer<AudioBufferList> {
    let _bufferList = AudioBufferList.allocate(maximumBuffers: 1)

    _bufferList[0].mDataByteSize = UInt32(dataByteSize)
    let alignment = MemoryLayout<UInt8>.alignment
    let mData = UnsafeMutableRawPointer.allocate(byteCount: dataByteSize, alignment: alignment)
    _bufferList[0].mData = mData
    _bufferList[0].mNumberChannels = 2

    return _bufferList.unsafeMutablePointer
}
