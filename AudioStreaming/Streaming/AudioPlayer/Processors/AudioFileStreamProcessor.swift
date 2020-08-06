//
//  Created by Dimitrios Chatzieleftheriou on 16/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//
//  Inspired by Thong Nguyen's StreamingKit. All rights reserved.
//

import AVFoundation

enum AudioConvertStatus: Int32 {
    case done = 100
    case proccessed = 0
}

struct AudioConvertInfo {
    var done: Bool
    let numberOfPackets: UInt32
    var audioBuffer = AudioBuffer()
    let packDescription: UnsafeMutablePointer<AudioStreamPacketDescription>?
}

final class AudioFileStreamProcessor {
    private let maxCompressedPacketForBitrate = 4_096
    
    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let audioFormat: AVAudioFormat
    
    internal var audioFileStream: AudioFileStreamID? = nil
    internal var audioConverter: AudioConverterRef? = nil
    internal var audioConverterStreamDescription = AudioStreamBasicDescription()
    
    var isFileStreamOpen: Bool {
        audioFileStream != nil
    }
    private let audioSemaphore: DispatchSemaphore
    
    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         semaphore: DispatchSemaphore,
         audioFormat: AVAudioFormat) {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.audioSemaphore = semaphore
        self.audioFormat = audioFormat
    }
    
    func openFileStream(with fileHint: AudioFileTypeID) -> OSStatus {
        let data = UnsafeMutableRawPointer.from(object: self)
        let status = AudioFileStreamOpen(data, _propertyListenerProc, _propertyPacketsProc, fileHint, &audioFileStream)
        return status
    }
    
    func closeFileStreamIfNeeded() {
        if let fileStream = audioFileStream {
            AudioFileStreamClose(fileStream)
            audioFileStream = nil
        }
    }
    
    func parseFileSteamBytes(buffer: UnsafeMutablePointer<UInt8>, size: Int) -> OSStatus {
        guard let stream = audioFileStream else { return 0 }
        return AudioFileStreamParseBytes(stream, UInt32(size), buffer, .init())
    }
    
    func createAudioConverter(from fromFormat: AVAudioFormat, to toFormat: AVAudioFormat) {
        var streamDescription = fromFormat.basicStreamDescription
        if let converter = audioConverter,
           memcmp(&streamDescription, &audioConverterStreamDescription, MemoryLayout.size(ofValue: AudioStreamBasicDescription.self)) != 0 {
            AudioConverterReset(converter)
        }
        destroyAudioConverter()
        
        
        var classDesc = AudioClassDescription()
        var canonical = toFormat.basicStreamDescription
        if getHardwareCodecClassDescripition(formatId: streamDescription.mFormatID, classDesc: &classDesc) {
            AudioConverterNewSpecific(&streamDescription, &canonical, 1, &classDesc, &audioConverter)
        }
        
        if audioConverter == nil {
            guard AudioConverterNew(&streamDescription, &canonical, &audioConverter) == noErr else {
                // raise error...
                return
            }
        }
        audioConverterStreamDescription = streamDescription
        
        // magic cookie info
        let fileHint = playerContext.currentReadingEntry?.source.audioFileHint
        if let fileStream = audioFileStream, fileHint != kAudioFileAAC_ADTSType {
            var cookieSize: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr else {
                return
            }
            var cookie: [UInt8] = Array(repeating: 0, count: Int(cookieSize))
            guard AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr else {
                return
            }
            guard AudioFileStreamSetProperty(fileStream, kAudioConverterDecompressionMagicCookie, cookieSize, cookie) == noErr else {
                // todo raise error
                return
            }
        }
    }
    
    private func destroyAudioConverter() {
        guard let converter = audioConverter else { return }
        AudioConverterDispose(converter)
        audioConverter = nil
    }
    
    func propertyListenerProc(processor: AudioFileStreamProcessor,
                              fileStream: AudioFileStreamID,
                              propertyId: AudioFileStreamPropertyID,
                              flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        switch propertyId {
            case kAudioFileStreamProperty_DataOffset:
                processDataOffset(fileStream: fileStream)
            case kAudioFileStreamProperty_FileFormat:
                processFileFormat(fileStream: fileStream)
            case kAudioFileStreamProperty_DataFormat:
                processDataFormat(fileStream: fileStream)
            case kAudioFileStreamProperty_AudioDataByteCount:
                processDataByteCount(fileStream: fileStream)
            case kAudioFileStreamProperty_ReadyToProducePackets:
                // check converter for discontious stream
                processReadyToProducePackets(fileStream: fileStream)
                break
            case kAudioFileStreamProperty_FormatList:
                processFormatList(fileStream: fileStream)
            default: break
        }
    }
    
    private func processDataOffset(fileStream: AudioFileStreamID) {
        var offset: UInt64 = 0
        fileStreamGetProperty(value: &offset, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataOffset)
        playerContext.currentReadingEntry?.parsedHeader = true
        playerContext.currentReadingEntry?.audioDataOffset = offset
    }
    
    private func processReadyToProducePackets(fileStream: AudioFileStreamID) {
        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout.size(ofValue: packetCount))
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_AudioDataPacketCount, &packetCountSize, &packetCount)
        playerContext.currentPlayingEntry?.packetCount = Double(packetCount)
    }
    
    private func processFileFormat(fileStream: AudioFileStreamID) {
        var fileFormat: [UInt8] = Array(repeating: 0, count: 4)
        var size = UInt32(4)
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_FileFormat, &size, &fileFormat)
        if let stringFileFormat = String(data: Data(fileFormat), encoding: .utf8) {
            rendererContext.fileFormat = stringFileFormat
        }
    }
    
    private func processDataFormat(fileStream: AudioFileStreamID) {
        var description = AudioStreamBasicDescription()
        guard let entry = playerContext.currentReadingEntry else { return }
        if !entry.parsedHeader {
            fileStreamGetProperty(value: &description, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataFormat)
            var packetBufferSize: UInt32 = 0
            var status = fileStreamGetProperty(value: &packetBufferSize, fileStream: fileStream, propertyId: kAudioFileStreamProperty_PacketSizeUpperBound)
            if status != 0 || packetBufferSize == 0 {
                status = fileStreamGetProperty(value: &packetBufferSize, fileStream: fileStream, propertyId: kAudioFileStreamProperty_MaximumPacketSize)
                if status != 0 || packetBufferSize == 0 {
                    packetBufferSize = 2048 // default value
                }
            }
            playerContext.entriesLock.lock()
            if playerContext.currentReadingEntry?.audioStreamFormat.basicStreamDescription.mFormatID == 0 {
                let audioFormat = AVAudioFormat(streamDescription: &description)
                playerContext.currentReadingEntry?.audioStreamFormat = audioFormat ?? AVAudioFormat()
            }
            playerContext.entriesLock.unlock()
            playerContext.currentReadingEntry?.lock.around {
                playerContext.currentPlayingEntry?.processedPacketsState.buferSize = packetBufferSize
            }
        }
        if let readingEntry = playerContext.currentReadingEntry {
            createAudioConverter(from: readingEntry.audioStreamFormat, to: audioFormat)
        }
    }
    
    private func processDataByteCount(fileStream: AudioFileStreamID) {
        guard let entry = playerContext.currentReadingEntry else { return }
        var audioDataByteCount: UInt64 = 0
        fileStreamGetProperty(value: &audioDataByteCount, fileStream: fileStream, propertyId: kAudioFileStreamProperty_AudioDataByteCount)
        entry.audioDataByteCount = audioDataByteCount
    }
    
    private func processFormatList(fileStream: AudioFileStreamID) {
        let info = fileStreamGetPropertyInfo(fileStream: fileStream, propertyId: kAudioFileStreamProperty_FormatList)
        guard info.status == noErr else { return }
        var list: [AudioFormatListItem] = Array(repeating: AudioFormatListItem(), count: Int(info.size))
        var size = UInt32(info.size)
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_FormatList, &size, &list)
        let step = MemoryLayout<AudioFormatListItem>.size
        var i = 0
        while i * step < size {
            var asbd = list[i].mASBD
            let formatId = asbd.mFormatID
            if formatId == kAudioFormatMPEG4AAC_HE || formatId == kAudioFormatMPEG4AAC_HE_V2 || formatId == kAudioFileAAC_ADTSType {
                if let audioFormat = AVAudioFormat(streamDescription: &asbd) {
                    playerContext.currentPlayingEntry?.audioStreamFormat = audioFormat
                }
                break
            }
            i += step
        }
    }
    
    // MARK: Packets Proc
    func propertyPacketsProc(processor: AudioFileStreamProcessor,
                             inNumberBytes: UInt32,
                             inNumberPackets: UInt32,
                             inInputData: UnsafeRawPointer,
                             inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let entry = playerContext.currentReadingEntry, entry.parsedHeader && !playerContext.disposedRequested else { return }
        
        if let playingEntry = playerContext.currentPlayingEntry,
           rendererContext.seekRequest.requested && playingEntry.calculatedBitrate() > 0 {
            // TODO call proccess source on player...
            return
        }
        
        guard let converter = self.audioConverter else { return }
        
        var convertInfo = AudioConvertInfo(done: false,
                                           numberOfPackets: inNumberPackets,
                                           packDescription: inPacketDescriptions)
        convertInfo.audioBuffer.mData = UnsafeMutableRawPointer(mutating: inInputData)
        convertInfo.audioBuffer.mDataByteSize = inNumberBytes
        convertInfo.audioBuffer.mNumberChannels = audioConverterStreamDescription.mChannelsPerFrame
        
        if let readingEntry = playerContext.currentReadingEntry, let inPacketDescriptions = inPacketDescriptions {
            let processedPackCount = readingEntry.processedPacketsState.count
            if processedPackCount < maxCompressedPacketForBitrate {
                let count = min(Int(inNumberPackets), maxCompressedPacketForBitrate - Int(processedPackCount))
                for i in 0..<count {
                    let packet = inPacketDescriptions[i]
                    let packetSize: UInt32 = packet.mDataByteSize
                    readingEntry.lock.lock()
                    readingEntry.processedPacketsState.sizeTotal += packetSize
                    readingEntry.processedPacketsState.count += 1
                    readingEntry.lock.unlock()
                }
            }
        }
        
        var status: OSStatus = noErr
        packetProccess: while status == noErr {
            rendererContext.lock.lock()
            let bufferContext = rendererContext.bufferContext
            var used = bufferContext.frameUsedCount
            var start = bufferContext.frameStartIndex
            var end = bufferContext.end
            
            var framesLeftInBuffer = max(bufferContext.totalFrameCount &- used, 0)
            rendererContext.lock.unlock()
            
            if framesLeftInBuffer == 0 {
                rendererContext.lock.lock()
                let bufferContext = rendererContext.bufferContext
                used = bufferContext.frameUsedCount
                start = bufferContext.frameStartIndex
                end = bufferContext.end
                framesLeftInBuffer = max(bufferContext.totalFrameCount &- used, 0)
                rendererContext.lock.unlock()
                if framesLeftInBuffer > 0 {
                    break packetProccess
                }
                if self.playerContext.disposedRequested
                    || self.playerContext.internalState == .disposed
                    || self.playerContext.internalState == .pendingNext
                    || self.playerContext.internalState == .stopped {
                    return
                }
                // TODO: check for seek time and proccess
                self.rendererContext.waiting = true
                self.audioSemaphore.wait()
                self.rendererContext.waiting = false
            }
            
            let localBufferList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { localBufferList.unsafeMutablePointer.deallocate() }
            
            if end >= start {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = rendererContext.bufferContext.totalFrameCount - end
                
                let offset: Int = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(list: localBufferList,
                                       dataOffset: offset,
                                       framesToDecode: framesToDecode)
                
                status = AudioConverterFillComplexBuffer(converter, _converterCallback, &convertInfo, &framesToDecode, localBufferList.unsafeMutablePointer, nil)
                
                framesAdded = framesToDecode
                
                if status == AudioConvertStatus.done.rawValue {
                    filUsedFrames(framesCount: framesAdded)
                    return
                } else if status != 0 {
                    /// raise undexpected error... codec error
                    return
                }
                
                framesToDecode = start
                if framesToDecode == 0 {
                    filUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                }
                prefillLocalBufferList(list: localBufferList,
                                       dataOffset: 0,
                                       framesToDecode: framesToDecode)
                
                status = AudioConverterFillComplexBuffer(converter, _converterCallback, &convertInfo, &framesToDecode, localBufferList.unsafeMutablePointer, nil)
                
                framesAdded += framesToDecode
                
                if status == AudioConvertStatus.done.rawValue {
                    filUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.proccessed.rawValue {
                    filUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                } else if status != 0 {
                    /// raise undexpected error... codec error
                    return
                }
                
            } else {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = start - end
                
                let offset: Int = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(list: localBufferList,
                                       dataOffset: offset,
                                       framesToDecode: framesToDecode)
                
                status = AudioConverterFillComplexBuffer(converter, _converterCallback, &convertInfo, &framesToDecode, localBufferList.unsafeMutablePointer, nil)
                
                framesAdded = framesToDecode
                if status == AudioConvertStatus.done.rawValue {
                    filUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.proccessed.rawValue {
                    filUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                } else if status != 0 {
                    /// raise undexpected error... codec error
                    return
                }
            }
        }
    }
    
    private func prefillLocalBufferList(list: UnsafeMutableAudioBufferListPointer, dataOffset: Int, framesToDecode: UInt32) {
        if let mData = rendererContext.audioBuffer.mData {
            if dataOffset > 0 {
                list[0].mData = mData + dataOffset
            } else {
                list[0].mData = mData
            }
        }
        list[0].mDataByteSize = framesToDecode * rendererContext.bufferContext.sizeInBytes
        list[0].mNumberChannels = rendererContext.audioBuffer.mNumberChannels
    }
    
    private func filUsedFrames(framesCount: UInt32) {
        rendererContext.lock.around {
            rendererContext.bufferContext.frameUsedCount += framesCount
        }
        playerContext.currentReadingEntry?.lock.around {
            playerContext.currentReadingEntry?.framesState.queued += Int(framesCount)
        }
    }
}

// MARK: - AudioFileStream proc method

private func _propertyListenerProc(clientData: UnsafeMutableRawPointer,
                                   fileStream: AudioFileStreamID,
                                   propertyId: AudioFileStreamPropertyID,
                                   flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyListenerProc(processor: processor,
                                   fileStream: fileStream,
                                   propertyId: propertyId,
                                   flags: flags)
}

private func _propertyPacketsProc(clientData: UnsafeMutableRawPointer,
                                  inNumberBytes: UInt32,
                                  inNumberPackets: UInt32,
                                  inInputData: UnsafeRawPointer,
                                  inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyPacketsProc(processor: processor,
                                  inNumberBytes: inNumberBytes,
                                  inNumberPackets: inNumberPackets,
                                  inInputData: inInputData,
                                  inPacketDescriptions: inPacketDescriptions)
}

// MARK: - AudioConverterFillComplexBuffer callback method

private func _converterCallback(inAudioConverter: AudioConverterRef,
                                ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                ioData: UnsafeMutablePointer<AudioBufferList>,
                                outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                                inUserData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let convertInfo = inUserData?.assumingMemoryBound(to: AudioConvertInfo.self) else { return 0 }
    
    if convertInfo.pointee.done {
        ioNumberDataPackets.pointee = 0
        return AudioConvertStatus.done.rawValue
    }
    // calculate the input buffer
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = convertInfo.pointee.audioBuffer
    convertInfo.pointee.audioBuffer.mData = nil
    convertInfo.pointee.audioBuffer.mDataByteSize = 0

    // output the packet descriptions
    ioNumberDataPackets.pointee = convertInfo.pointee.numberOfPackets
    if outDataPacketDescription != nil {
        outDataPacketDescription?.pointee = convertInfo.pointee.packDescription
    }
    convertInfo.pointee.done = true

    return AudioConvertStatus.proccessed.rawValue
}

// MARK: HardwareCodedClass method
private func getHardwareCodecClassDescripition(formatId: UInt32, classDesc: UnsafeMutablePointer<AudioClassDescription>) -> Bool {
    #if os(iOS)
    var size: UInt32 = 0
    let formatIdSize = UInt32(MemoryLayout.size(ofValue: formatId))
    var id = formatId
    if AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, formatIdSize, &id, &size) != noErr {
        return false
    }
    let count = Int(size) / MemoryLayout<AudioClassDescription>.size
    var encoderDescriptions = Array(repeating: AudioClassDescription(), count: count)
    if AudioFormatGetProperty(kAudioFormatProperty_Decoders, formatIdSize, &id, &size, &encoderDescriptions) != noErr {
        return false
    }
    
    for item in encoderDescriptions {
        if item.mManufacturer == kAppleHardwareAudioCodecManufacturer {
            classDesc.pointee = item
            return true
        }
    }
    #endif
    return false
}
