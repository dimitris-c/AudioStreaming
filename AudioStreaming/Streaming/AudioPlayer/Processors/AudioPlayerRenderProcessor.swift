//
//  Created by Dimitrios Chatzieleftheriou on 18/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//
//  Inspired by Thong Nguyen's StreamingKit. All rights reserved.
//

import AVFoundation

final class AudioPlayerRenderProcessor: NSObject {
    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription
    /// The AVAudioEngine's `AVAudioEngineManualRenderingBlock` render block from manual rendering
    var renderBlock: AVAudioEngineManualRenderingBlock?
    
    /// A block that notifies if the audio entry has finished playing
    var audioFinished: ((_ entry: AudioEntry?) -> Void)?
    
    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription) {
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
        let isMuted = playerContext.muted
        playerContext.entriesLock.unlock()
        
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
        let framesConsumedSignal = rendererContext.waiting && used < bufferContext.totalFrameCount / 2
        
        if let playingEntry = playingEntry {
            if state == .waitingForData {
                var requiredFramesToStart = rendererContext.framesRequestToStartPlaying
                if playingEntry.framesState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(playingEntry.framesState.lastFrameQueued))
                }
                if let readingEntry = readingEntry,
                   readingEntry === playingEntry && playingEntry.framesState.queued < requiredFramesToStart {
                    waitForBuffer = true
                }
            } else if state == .rebuffering {
                var requiredFramesToStart = rendererContext.framesRequiredAfterRebuffering
                let frameState = playingEntry.framesState
                if frameState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(frameState.lastFrameQueued - frameState.queued))
                }
                if used < requiredFramesToStart {
                    waitForBuffer = true
                }
            } else if state == .waitingForDataAfterSeek {
                var requiredFramesToStart: Int = 1024
                let frameState = playingEntry.framesState
                if frameState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, frameState.lastFrameQueued - frameState.queued)
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
                    memset(bufferList.mBuffers.mData,
                           0,
                           Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let mDataBuffer = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData,
                               mDataBuffer + Int(start * frameSizeInBytes),
                               Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                totalFramesCopied = framesToCopy
                
                rendererContext.lock.lock()
                rendererContext.bufferContext.frameStartIndex = (rendererContext.bufferContext.frameStartIndex + totalFramesCopied) % rendererContext.bufferContext.totalFrameCount
                rendererContext.bufferContext.frameUsedCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            } else {
                let frameToCopy = min(inNumberFrames, rendererContext.bufferContext.totalFrameCount - start)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * frameToCopy
                
                if isMuted {
                    memset(bufferList.mBuffers.mData,
                           0,
                           Int(bufferList.mBuffers.mDataByteSize))
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
                    if let mDataBuffer = bufferList.mBuffers.mData {
                        if isMuted {
                            memset(mDataBuffer + Int(frameToCopy * frameSizeInBytes),
                                   0,
                                   Int(frameSizeInBytes * moreFramesToCopy))
                        } else {
                            if let mDataBuffer = audioBuffer.mData {
                                memcpy(mDataBuffer + Int(frameToCopy * frameSizeInBytes),
                                       mDataBuffer,
                                       Int(frameSizeInBytes * moreFramesToCopy))
                            }
                        }
                    }
                }
                totalFramesCopied = frameToCopy + moreFramesToCopy

                rendererContext.lock.lock()
                rendererContext.bufferContext.frameStartIndex = (rendererContext.bufferContext.frameStartIndex + totalFramesCopied) % rendererContext.bufferContext.totalFrameCount
                rendererContext.bufferContext.frameUsedCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            }
            if playerContext.internalState != .playing {
                playerContext.setInternalState(to: .playing) { state -> Bool in
                    state.contains(.running) && state != .paused
                }                
            }
            
        }
        
        if totalFramesCopied < inNumberFrames {
            let delta = inNumberFrames - totalFramesCopied
            if let mData = bufferList.mBuffers.mData {
                memset(mData + Int(totalFramesCopied * frameSizeInBytes),
                       0,
                       Int(delta * frameSizeInBytes))
            }
            if playingEntry != nil || state == .waitingForDataAfterSeek || state == .waitingForData || state == .rebuffering {
                // buffering
                if playerContext.internalState != .rebuffering {
                    playerContext.setInternalState(to: .rebuffering) { state -> Bool in
                        state.contains(.running) && state != .paused
                    }                    
                }
            } else if state == .waitingForDataAfterSeek {
                // todo: implement this
            }
        }
        
        guard let currentPlayingEntry = playingEntry else {
            return nil
        }
        currentPlayingEntry.lock.lock()
        
        var extraFramesPlayedNotAssigned: UInt32 = 0
        var framesPlayedForCurrent = totalFramesCopied

        if currentPlayingEntry.framesState.lastFrameQueued >= 0 {
            framesPlayedForCurrent = min(UInt32(currentPlayingEntry.framesState.lastFrameQueued - currentPlayingEntry.framesState.played), framesPlayedForCurrent)
        }
        
        currentPlayingEntry.framesState.played += Int(framesPlayedForCurrent)
        extraFramesPlayedNotAssigned = totalFramesCopied - framesPlayedForCurrent
        
        let lastFramePlayed = currentPlayingEntry.framesState.isAtEnd
        
        currentPlayingEntry.lock.unlock()
        if framesConsumedSignal || lastFramePlayed {
            
            if lastFramePlayed && playingEntry === playerContext.audioPlayingEntry {
                audioFinished?(playingEntry)
                
                while extraFramesPlayedNotAssigned > 0 {
                    if let newEntry = playerContext.audioPlayingEntry {
                        var framesPlayedForCurrent = extraFramesPlayedNotAssigned
                        
                        let framesState = newEntry.framesState
                        if newEntry.framesState.lastFrameQueued > 0 {
                            framesPlayedForCurrent = min(UInt32(framesState.lastFrameQueued - framesState.played), framesPlayedForCurrent)
                        }
                        newEntry.lock.lock()
                        newEntry.framesState.played += Int(framesPlayedForCurrent)
                        
                        if framesState.isAtEnd {
                            newEntry.lock.unlock()
                            audioFinished?(newEntry)
                        } else {
                            newEntry.lock.unlock()
                        }
                        
                        extraFramesPlayedNotAssigned -= framesPlayedForCurrent
                        
                    } else {
                        break
                    }
                }
            }
            
            rendererContext.packetsSemaphore.signal()
        }

        rendererContext.inOutAudioBufferList[0].mBuffers.mData = bufferList.mBuffers.mData
        rendererContext.inOutAudioBufferList[0].mBuffers.mDataByteSize = bufferList.mBuffers.mDataByteSize
        rendererContext.inOutAudioBufferList[0].mBuffers.mNumberChannels = outputAudioFormat.mChannelsPerFrame
        
        return UnsafePointer(rendererContext.inOutAudioBufferList)
    }
    
    func render(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>, status: OSStatus) -> OSStatus {
        var status = status

        let mChannelsPerFrame = outputAudioFormat.mChannelsPerFrame
        rendererContext.inOutAudioBufferList[0].mBuffers.mData = ioData.pointee.mBuffers.mData
        rendererContext.inOutAudioBufferList[0].mBuffers.mDataByteSize = ioData.pointee.mBuffers.mDataByteSize
        rendererContext.inOutAudioBufferList[0].mBuffers.mNumberChannels = mChannelsPerFrame
        
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
                    print("report error")
                    return 0
                case .error:
                    print("report error")
                    return 0
                @unknown default:
                    print("report error")
                    return 0
            }
        }
        return status
    }
    
    func renderProvider(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, inNumberFrames: AUAudioFrameCount, inputBusNumber: Int, inputData: UnsafeMutablePointer<AudioBufferList>) -> AUAudioUnitStatus {
        let status = noErr
        return render(inNumberFrames: inNumberFrames, ioData: inputData, status: status)
    }
}
