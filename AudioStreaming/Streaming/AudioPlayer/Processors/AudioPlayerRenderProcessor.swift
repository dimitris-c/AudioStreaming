//
//  Created by Dimitrios Chatzieleftheriou on 18/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

final class AudioPlayerRenderProcessor: NSObject {
    private(set) var playerContext: AudioPlayerContext
    private(set) var rendererContext: AudioRendererContext
    
    private(set) var audioQueue: DispatchQueue
    private(set) var audioSemaphore: DispatchSemaphore
    
    init(playerContext: AudioPlayerContext, rendererContext: AudioRendererContext, queue: DispatchQueue, semaphore: DispatchSemaphore) {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.audioQueue = queue
        self.audioSemaphore = semaphore
    }
    
    func attachCallback(on player: AVAudioUnit) {
        
        var description = UnitDescriptions.canonicalAudioStream
        let size = MemoryLayout.size(ofValue: description)
        
        AudioUnitSetProperty(player.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &description, UInt32(size))
        
        let framesPerSliceSize = MemoryLayout.size(ofValue: maxFramesPerSlice)
        AudioUnitSetProperty(player.audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(framesPerSliceSize))
        
        let refCon = UnsafeMutableRawPointer.from(object: self)
        var callback = AURenderCallbackStruct(inputProc: renderCallback,
                                              inputProcRefCon: refCon)
        let callbackSize = MemoryLayout.size(ofValue: callback)
        AudioUnitSetProperty(player.audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(callbackSize))
    }
    
    func inRender(inNumberFrames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        playerContext.entriesLock.lock()
        let entry = playerContext.currentPlayingEntry
        let readingEntry = playerContext.currentReadingEntry
        playerContext.entriesLock.unlock()
        
        let state = playerContext.internalState
        
        rendererContext.lock.lock()
        
        var waitForBuffer = false
        let isMuted = playerContext.muted
        let audioBuffer = rendererContext.audioBuffer
        var bufferList = rendererContext.outAudioBufferList[0]
        let frameSizeInBytes = rendererContext.bufferFrameSizeInBytes
        let used = rendererContext.bufferUsedFrameCount
        let start = rendererContext.bufferFramesStartIndex
        let end = (rendererContext.bufferFramesStartIndex + rendererContext.bufferUsedFrameCount) % rendererContext.bufferTotalFrameCount
        let signal = rendererContext.waiting && used < rendererContext.bufferTotalFrameCount / 2
        
        if let playingEntry = entry {
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
                    memset(bufferList.mBuffers.mData, 0, Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let buffermData = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData, buffermData + Int(start * frameSizeInBytes), Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                totalFramesCopied = framesToCopy
                
                rendererContext.lock.lock()
                rendererContext.bufferFramesStartIndex = (rendererContext.bufferFramesStartIndex + totalFramesCopied) % rendererContext.bufferTotalFrameCount
                rendererContext.bufferUsedFrameCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            } else {
                let frameToCopy = min(inNumberFrames, rendererContext.bufferTotalFrameCount - start)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * frameToCopy
                
                if isMuted {
                    memset(bufferList.mBuffers.mData, 0, Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let buffermData = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData, buffermData + Int(start * frameSizeInBytes), Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                
                var moreFramesToCopy: UInt32 = 0
                let delta = inNumberFrames - frameToCopy
                if delta > 0 {
                    moreFramesToCopy = min(delta, end)
                    bufferList.mBuffers.mNumberChannels = 2
                    bufferList.mBuffers.mDataByteSize += frameSizeInBytes * moreFramesToCopy
                    if let iomData = bufferList.mBuffers.mData {
                        if isMuted {
                            memset(iomData + Int(frameToCopy * frameSizeInBytes), 0, Int(frameSizeInBytes * moreFramesToCopy))
                        } else {
                            if let buffermData = audioBuffer.mData {
                                memcpy(iomData + Int(frameToCopy * frameSizeInBytes), buffermData, Int(frameSizeInBytes * moreFramesToCopy))
                            }
                        }
                    }
                }
                totalFramesCopied = frameToCopy + moreFramesToCopy

                rendererContext.lock.lock()
                rendererContext.bufferFramesStartIndex = (rendererContext.bufferFramesStartIndex + totalFramesCopied) % rendererContext.bufferTotalFrameCount
                rendererContext.bufferUsedFrameCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            }
            playerContext.setInternalState(to: .playing) { state -> Bool in
                state.contains(.running) && state != .paused
            }
            
        }
        
        if totalFramesCopied < inNumberFrames {
            let delta = inNumberFrames - totalFramesCopied
            if let mData = bufferList.mBuffers.mData {
                memset(mData + Int((totalFramesCopied * frameSizeInBytes)), 0, Int(delta * frameSizeInBytes))
            }
            if playerContext.currentPlayingEntry != nil || state == .waitingForDataAfterSeek || state == .waitingForData || state == .rebuffering {
                // buffering
                playerContext.setInternalState(to: .rebuffering) { state -> Bool in
                    state.contains(.running) && state != .paused
                }
            } else if state == .waitingForDataAfterSeek {
                // todo: implement this
            }
        }
        
        guard let currentPlayingEntry = entry else {
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
        
        let lastFramePlayed = currentPlayingEntry.framesState.played == currentPlayingEntry.framesState.lastFrameQueued
        
        currentPlayingEntry.lock.unlock()
        
        if signal || lastFramePlayed {
            
            if lastFramePlayed && entry === playerContext.currentPlayingEntry {
                // todo call audio queue finished playing on audio player
                
                while extraFramesPlayedNotAssigned > 0 {
                    if let newEntry = playerContext.currentPlayingEntry {
                        var framesPlayedForCurrent = extraFramesPlayedNotAssigned
                        
                        let framesState = newEntry.framesState
                        if newEntry.framesState.lastFrameQueued > 0 {
                            framesPlayedForCurrent = min(UInt32(framesState.lastFrameQueued - framesState.played), framesPlayedForCurrent)
                        }
                        newEntry.lock.lock()
                        newEntry.framesState.played += Int(framesPlayedForCurrent)
                        
                        if framesState.played == framesState.lastFrameQueued {
                            newEntry.lock.unlock()
                            //
                            // todo call audio queue finished playing on audio player on newEntry
                        }
                        newEntry.lock.unlock()
                        
                        extraFramesPlayedNotAssigned -= framesPlayedForCurrent
                        
                    } else {
                        break
                    }
                }
            }
            
            self.audioSemaphore.signal()
        }
        
        let bytesPerFrames = UnitDescriptions.canonicalAudioStream.mBytesPerFrame
        let size = max(inNumberFrames, bytesPerFrames * totalFramesCopied)

        rendererContext.inAudioBufferList[0].mBuffers.mData = rendererContext.outAudioBufferList[0].mBuffers.mData
        rendererContext.inAudioBufferList[0].mBuffers.mDataByteSize = size
        rendererContext.inAudioBufferList[0].mBuffers.mNumberChannels = UnitDescriptions.canonicalAudioStream.mChannelsPerFrame
        
        return UnsafePointer(rendererContext.inAudioBufferList)
    }
    
    func render(inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>, status: OSStatus) -> OSStatus {
        var status = status
        
        rendererContext.outAudioBufferList[0].mBuffers.mData = ioData.pointee.mBuffers.mData
        rendererContext.outAudioBufferList[0].mBuffers.mDataByteSize = ioData.pointee.mBuffers.mDataByteSize
        rendererContext.outAudioBufferList[0].mBuffers.mNumberChannels = UnitDescriptions.canonicalAudioStream.mChannelsPerFrame
        
        if let renderStatus = rendererContext.renderBlock?(inNumberFrames, rendererContext.outAudioBufferList, &status) {
            switch renderStatus {
                case .success:
                    return 0
                case .insufficientDataFromInputNode:
                    return 0
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
}

private func renderCallback(userInfo: UnsafeMutableRawPointer, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp _: UnsafePointer<AudioTimeStamp>, inBusNumber _: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let userData = userInfo.to(type: AudioPlayerRenderProcessor.self)
    let status = noErr
    return userData.render(inNumberFrames: inNumberFrames, ioData: ioData!, status: status)
}

