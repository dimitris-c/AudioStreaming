//
//  Created by Dimitrios Chatzieleftheriou on 18/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//
//  Inspired by Thong Nguyen's StreamingKit. All rights reserved.
//

import AVFoundation

final class AudioPlayerRenderProcessor: NSObject {
    /// The AVAudioEngine's `AVAudioEngineManualRenderingBlock` render block from manual rendering
    var renderBlock: AVAudioEngineManualRenderingBlock?

    /// A block that notifies if the audio entry has finished playing
    var audioFinishedPlaying: ((_ entry: AudioEntry?) -> Void)?

    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription

    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription)
    {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
    }

    func attachCallback(on player: AVAudioUnit, audioFormat: AVAudioFormat) {
        if player.auAudioUnit.inputBusses.count > 0 {
            do {
                try player.auAudioUnit.inputBusses[0].setFormat(audioFormat)
            } catch {
                Logger.error("Player auAudioUnit inputbus failure %@",
                             category: .audioRendering,
                             args: error.localizedDescription)
            }
        }
        // set the max frames to render
        player.auAudioUnit.maximumFramesToRender = maxFramesPerSlice

        // sets the render provider callback
        player.auAudioUnit.outputProvider = renderProvider
    }

    /// Provides data to the audio engine
    ///
    /// - parameter inNumberFrames: An `AVAudioFrameCount` provided by the `AudioEngine` instance
    /// - returns An optional `UnsafePointer` of `AudioBufferList`
    func inRender(inNumberFrames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        playerContext.entriesLock.lock()
        let playingEntry = playerContext.audioPlayingEntry
        let readingEntry = playerContext.audioReadingEntry
        playerContext.entriesLock.unlock()
        let isMuted = playerContext.muted.value
        let state = playerContext.internalState

        rendererContext.lock.lock()
        var waitForBuffer = false
        let audioBuffer = rendererContext.audioBuffer
        var bufferList = rendererContext.inOutAudioBufferList[0]
        let bufferContext = rendererContext.bufferContext
        let frameSizeInBytes = bufferContext.sizeInBytes
        let used = bufferContext.frameUsedCount
        let start = bufferContext.frameStartIndex
        let end = bufferContext.end
        let signal = rendererContext.waiting.value && used < bufferContext.totalFrameCount / 2

        if let playingEntry = playingEntry {
            playingEntry.lock.lock()
            let framesState = playingEntry.framesState
            playingEntry.lock.unlock()
            if state == .waitingForData {
                var requiredFramesToStart = rendererContext.framesRequiredToStartPlaying
                if framesState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(playingEntry.framesState.lastFrameQueued))
                }
                if let readingEntry = readingEntry, readingEntry === playingEntry,
                   framesState.queued < requiredFramesToStart
                {
                    waitForBuffer = true
                }
            } else if state == .rebuffering {
                var requiredFramesToStart = rendererContext.framesRequiredAfterRebuffering
                if framesState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(framesState.lastFrameQueued - framesState.queued))
                }
                if used < requiredFramesToStart {
                    waitForBuffer = true
                }
            } else if state == .waitingForDataAfterSeek {
                var requiredFramesToStart: Int = 1024
                if framesState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, framesState.lastFrameQueued - framesState.queued)
                }
                if used < requiredFramesToStart {
                    waitForBuffer = true
                }
            }
        }
        rendererContext.lock.unlock()

        var totalFramesCopied: UInt32 = 0
        if used > 0 && !waitForBuffer && state.contains(.running) && state != .paused {
            if end > start {
                let framesToCopy = min(inNumberFrames, used)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * framesToCopy

                if isMuted {
                    writeSilence(outputBuffer: &bufferList.mBuffers,
                                 outputBufferSize: 0,
                                 offset: Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let mDataBuffer = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData,
                               mDataBuffer + Int(start * frameSizeInBytes),
                               Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                totalFramesCopied = framesToCopy

                rendererContext.lock.lock()
                bufferContext.frameStartIndex = (bufferContext.frameStartIndex + totalFramesCopied) % bufferContext.totalFrameCount
                bufferContext.frameUsedCount -= totalFramesCopied
                rendererContext.lock.unlock()

            } else {
                let frameToCopy = min(inNumberFrames, bufferContext.totalFrameCount - start)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * frameToCopy

                if isMuted {
                    writeSilence(outputBuffer: &bufferList.mBuffers,
                                 outputBufferSize: 0,
                                 offset: Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let mDataBuffer = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData,
                               mDataBuffer + Int(start * frameSizeInBytes),
                               Int(bufferList.mBuffers.mDataByteSize))
                    }
                }

                var moreFramesToCopy: UInt32 = 0
                let delta = inNumberFrames - frameToCopy
                if delta > 0 {
                    moreFramesToCopy = min(delta, end)
                    bufferList.mBuffers.mNumberChannels = 2
                    bufferList.mBuffers.mDataByteSize += frameSizeInBytes * moreFramesToCopy
                    if let ioBufferData = bufferList.mBuffers.mData {
                        if isMuted {
                            writeSilence(outputBuffer: &bufferList.mBuffers,
                                         outputBufferSize: Int(frameSizeInBytes * moreFramesToCopy),
                                         offset: Int(frameToCopy * frameSizeInBytes))
                        } else {
                            if let mDataBuffer = audioBuffer.mData {
                                memcpy(ioBufferData + Int(frameToCopy * frameSizeInBytes),
                                       mDataBuffer,
                                       Int(frameSizeInBytes * moreFramesToCopy))
                            }
                        }
                    }
                }
                totalFramesCopied = frameToCopy + moreFramesToCopy

                rendererContext.lock.lock()
                bufferContext.frameStartIndex = (bufferContext.frameStartIndex + totalFramesCopied) % bufferContext.totalFrameCount
                bufferContext.frameUsedCount -= totalFramesCopied
                rendererContext.lock.unlock()
            }
            if playerContext.internalState != .playing {
                playerContext.setInternalState(to: .playing, when: { state -> Bool in
                    state.contains(.running) && state != .paused
                })
            }
        }

        if totalFramesCopied < inNumberFrames {
            let delta = inNumberFrames - totalFramesCopied
            writeSilence(outputBuffer: &bufferList.mBuffers,
                         outputBufferSize: Int(delta * frameSizeInBytes),
                         offset: Int(totalFramesCopied * frameSizeInBytes))

            if playingEntry != nil || AudioPlayer.InternalState.waiting.contains(state) {
                if playerContext.internalState != .rebuffering {
                    playerContext.setInternalState(to: .rebuffering, when: { state -> Bool in
                        state.contains(.running) && state != .paused
                    })
                }
            } else if state == .waitingForDataAfterSeek {
                if totalFramesCopied == 0 {
                    rendererContext.waitingForDataAfterSeekFrameCount.write { $0 += Int32(inNumberFrames - totalFramesCopied) }
                    if rendererContext.waitingForDataAfterSeekFrameCount.value > rendererContext.framesRequiredForDataAfterSeekPlaying {
                        if playerContext.internalState != .playing {
                            playerContext.setInternalState(to: .playing) { state -> Bool in
                                state.contains(.running) && state != .playing
                            }
                        }
                        rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
                    }
                } else {
                    rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
                }
            }
        }

        guard let currentPlayingEntry = playingEntry else {
            return nil
        }
        currentPlayingEntry.lock.lock()

        var extraFramesPlayedNotAssigned: Int = 0
        var framesPlayedForCurrent = Int(totalFramesCopied)

        if currentPlayingEntry.framesState.lastFrameQueued >= 0 {
            let playedFrames = currentPlayingEntry.framesState.lastFrameQueued - currentPlayingEntry.framesState.played
            framesPlayedForCurrent = min(playedFrames, framesPlayedForCurrent)
        }

        currentPlayingEntry.framesState.played += Int(framesPlayedForCurrent)
        extraFramesPlayedNotAssigned = Int(totalFramesCopied) - framesPlayedForCurrent

        let lastFramePlayed = currentPlayingEntry.framesState.played == currentPlayingEntry.framesState.lastFrameQueued

        currentPlayingEntry.lock.unlock()
        if signal || lastFramePlayed {
            playerContext.entriesLock.lock()
            let entry = playerContext.audioPlayingEntry
            playerContext.entriesLock.unlock()
            if lastFramePlayed, playingEntry === entry {
                audioFinishedPlaying?(playingEntry)

                while extraFramesPlayedNotAssigned > 0 {
                    playerContext.entriesLock.lock()
                    let newEntry = playerContext.audioPlayingEntry
                    playerContext.entriesLock.unlock()
                    if let newEntry = newEntry {
                        var framesPlayedForCurrent = extraFramesPlayedNotAssigned

                        newEntry.lock.lock()
                        let framesState = newEntry.framesState
                        if newEntry.framesState.lastFrameQueued > 0 {
                            framesPlayedForCurrent = min(framesState.lastFrameQueued - framesState.played, framesPlayedForCurrent)
                        }

                        newEntry.framesState.played += framesPlayedForCurrent

                        if framesState.played == framesState.lastFrameQueued {
                            newEntry.lock.unlock()
                            audioFinishedPlaying?(newEntry)
                        } else {
                            newEntry.lock.unlock()
                        }

                        extraFramesPlayedNotAssigned -= framesPlayedForCurrent

                    } else {
                        break
                    }
                }
            }
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
        }

        rendererContext.inOutAudioBufferList[0].mBuffers.mData = bufferList.mBuffers.mData
        rendererContext.inOutAudioBufferList[0].mBuffers.mDataByteSize = bufferList.mBuffers.mDataByteSize
        rendererContext.inOutAudioBufferList[0].mBuffers.mNumberChannels = outputAudioFormat.mChannelsPerFrame

        return UnsafePointer(rendererContext.inOutAudioBufferList)
    }

    func render(inNumberFrames: UInt32,
                ioData: UnsafeMutablePointer<AudioBufferList>,
                flags _: UnsafeMutablePointer<AudioUnitRenderActionFlags>) -> OSStatus
    {
        var status = noErr

        rendererContext.inOutAudioBufferList[0].mBuffers.mData = ioData.pointee.mBuffers.mData
        rendererContext.inOutAudioBufferList[0].mBuffers.mDataByteSize = ioData.pointee.mBuffers.mDataByteSize
        rendererContext.inOutAudioBufferList[0].mBuffers.mNumberChannels = outputAudioFormat.mChannelsPerFrame

        let renderStatus = renderBlock?(inNumberFrames, rendererContext.inOutAudioBufferList, &status)

        // Regardless of the returned status code, the output buffer's
        // `mDataByteSize` field will indicate the amount of PCM data bytes
        // rendered by the engine
        let bytesTotal = rendererContext.inOutAudioBufferList[0].mBuffers.mDataByteSize

        if bytesTotal == 0 {
            guard let renderStatus = renderStatus else { return noErr }
            switch renderStatus {
            case .success:
                return noErr
            case .insufficientDataFromInputNode:
                return noErr
            case .cannotDoInCurrentContext:
                Logger.error("cannotDoInCurrentContext", category: .audioRendering)
                return 0
            case .error:
                Logger.error("generic error", category: .audioRendering)
                return 0
            @unknown default:
                Logger.error("unknown error", category: .audioRendering)
                return 0
            }
        }
        return status
    }

    func renderProvider(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timeStamp _: UnsafePointer<AudioTimeStamp>,
                        inNumberFrames: AUAudioFrameCount,
                        inputBusNumber: Int,
                        inputData: UnsafeMutablePointer<AudioBufferList>) -> AUAudioUnitStatus
    {
        guard inputBusNumber == 0 else { return noErr }
        return render(inNumberFrames: inNumberFrames, ioData: inputData, flags: flags)
    }

    @inline(__always)
    private func writeSilence(outputBuffer: inout AudioBuffer,
                              outputBufferSize: Int,
                              offset: Int)
    {
        guard let mData = outputBuffer.mData else { return }
        memset(mData + offset, 0, outputBufferSize)
        outputBuffer.mDataByteSize = UInt32(outputBufferSize)
        outputBuffer.mNumberChannels = outputAudioFormat.mChannelsPerFrame
    }
}
