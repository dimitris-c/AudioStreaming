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

enum FileStreamProcessorEffect {
    case proccessSource
    case raiseError(AudioPlayerError)
}

/// An object that handles the proccessing of AudioFileStream, its packets etc.
final class AudioFileStreamProcessor {
    private let maxCompressedPacketForBitrate = 4096

    var fileStreamCallback: ((FileStreamProcessorEffect) -> Void)?

    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription

    internal var audioFileStream: AudioFileStreamID?
    internal var audioConverter: AudioConverterRef?
    internal var discontinuous: Bool = false
    internal var inputFormat = AudioStreamBasicDescription()
    internal var fileFormat: String = ""
    internal let fa4mFormat = "fa4m"

    var isFileStreamOpen: Bool {
        audioFileStream != nil
    }

    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription)
    {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
    }

    /// Opens the `AudioFileStream`
    ///
    /// - parameter fileHint: An `AudioFileTypeID` value indicating the file type.
    ///
    /// - Returns: An `OSStatus` value indicating if an error occurred or not.

    func openFileStream(with fileHint: AudioFileTypeID) -> OSStatus {
        let data = UnsafeMutableRawPointer.from(object: self)
        return AudioFileStreamOpen(data, _propertyListenerProc, _propertyPacketsProc, fileHint, &audioFileStream)
    }

    /// Closes the currently open `AudioFileStream` instance, if opened.
    func closeFileStreamIfNeeded() {
        guard let fileStream = audioFileStream else {
            Logger.debug("audio file stream not opened", category: .generic)
            return
        }
        AudioFileStreamClose(fileStream)
        audioFileStream = nil
    }

    /// Parses the given data using `AudioFileStreamParseBytes`
    ///
    /// - parameter data: A `Data` object containing the audio data to be parsed.
    ///
    /// - Returns: An `OSStatus` value indicating if an error occurred or not.
    func parseFileStreamBytes(data: Data) -> OSStatus {
        guard let stream = audioFileStream else { return 0 }
        guard !data.isEmpty else { return 0 }
        let flags: AudioFileStreamParseFlags = discontinuous ? .discontinuity : .init()
        return data.withUnsafeBytes { buffer -> OSStatus in
            AudioFileStreamParseBytes(stream, UInt32(buffer.count), buffer.baseAddress, flags)
        }
    }

    func processSeek() {
        guard let stream = audioFileStream else { return }
        guard let readingEntry = playerContext.audioReadingEntry else {
            return
        }

        guard readingEntry.calculatedBitrate() > 0.0 || (playerContext.audioPlayingEntry?.length ?? 0) > 0 else {
            return
        }

        let dataOffset = Double(readingEntry.audioStreamState.dataOffset)
        let dataLengthInBytes = Double(readingEntry.audioDataLengthBytes())
        let entryDuration = readingEntry.duration()
        let duration = entryDuration < readingEntry.progress && entryDuration > 0 ? readingEntry.progress : entryDuration

        var seekByteOffset = Int64(dataOffset + (readingEntry.seekRequest.time / duration) * dataLengthInBytes)

        if seekByteOffset > readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)) {
            seekByteOffset = Int64(readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)))
        }

        readingEntry.lock.lock()
        readingEntry.seekTime = readingEntry.seekRequest.time
        readingEntry.lock.unlock()

        let bitrate = readingEntry.calculatedBitrate()
        if readingEntry.processedPacketsState.count > 0, bitrate > 0 {
            var ioFlags = AudioFileStreamSeekFlags(rawValue: 0)
            var packetsAlignedByteOffset: Int64 = 0
            let seekPacket = Int64(floor(readingEntry.seekRequest.time / readingEntry.packetDuration))

            let seekStatus = AudioFileStreamSeek(stream, seekPacket, &packetsAlignedByteOffset, &ioFlags)
            guard seekStatus == noErr else {
                let streamError = AudioFileStreamError(status: seekStatus)
                Logger.error("seek failed %@", category: .generic, args: streamError.debugDescription)
                return
            }

            let dataOffset = Int64(readingEntry.audioStreamState.dataOffset)
            if !ioFlags.contains(.offsetIsEstimated) {
                seekByteOffset = packetsAlignedByteOffset + dataOffset
                let delta = Double((seekByteOffset - dataOffset) - packetsAlignedByteOffset) / bitrate * 8

                readingEntry.lock.lock()
                readingEntry.seekTime -= delta
                readingEntry.lock.unlock()
            }
        }

        if let converted = audioConverter {
            AudioConverterReset(converted)
        }

        readingEntry.reset()
        readingEntry.seek(at: Int(seekByteOffset))
        rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
        playerContext.setInternalState(to: .waitingForDataAfterSeek)
        rendererContext.resetBuffers()
    }

    /// Creates an `AudioConverter` instance to be used for converting the remote audio data to the canonical audio format
    ///
    /// - parameter fromFormat: An `AudioStreamBasicDescription` indicating the format of the remote audio
    /// - parameter toFormat: An `AudioStreamBasicDescription` indicating the local format in which the fromFormat will be converted to.
    func createAudioConverter(from fromFormat: AudioStreamBasicDescription, to toFormat: AudioStreamBasicDescription) {
        var inputFormat = fromFormat
        if let converter = audioConverter {
            if memcmp(&inputFormat, &self.inputFormat, MemoryLayout<AudioStreamBasicDescription>.size) == 0 {
                AudioConverterReset(converter)
                return
            }
        }
        disposeAudioConverter()

        var classDesc = AudioClassDescription()
        var outputFormat = toFormat
        if getHardwareCodecClassDescripition(formatId: inputFormat.mFormatID, classDesc: &classDesc) {
            AudioConverterNewSpecific(&inputFormat, &outputFormat, 1, &classDesc, &audioConverter)
        }

        if audioConverter == nil {
            let audioConverterStatus = AudioConverterNew(&inputFormat, &outputFormat, &audioConverter)
            guard audioConverterStatus == noErr else {
                let audioConverterError = AudioConverterError(osstatus: audioConverterStatus)
                fileStreamCallback?(.raiseError(.audioSystemError(.converterError(audioConverterError))))
                return
            }
        }
        self.inputFormat = inputFormat

        // magic cookie info
        let fileHint = playerContext.audioReadingEntry?.audioFileHint
        let isProperFormat = fileHint != kAudioFileAAC_ADTSType && fileHint != kAudioFileM4AType && fileHint != kAudioFileMPEG4Type
        if let fileStream = audioFileStream, isProperFormat {
            var cookieSize: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr else {
                return
            }
            var cookie: [UInt8] = Array(repeating: 0, count: Int(cookieSize))
            guard AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr else {
                return
            }
            guard let converter = audioConverter else {
                fileStreamCallback?(.raiseError(.audioSystemError(.fileStreamError(.unknownError))))
                 return
            }
            guard AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie) == noErr else {
                fileStreamCallback?(.raiseError(.audioSystemError(.fileStreamError(.unknownError))))
                return
            }
        }
    }

    /// Disposes the `AudioConverter` instance, if any.
    private func disposeAudioConverter() {
        guard let converter = audioConverter else { return }
        AudioConverterDispose(converter)
        audioConverter = nil
    }

    /// Parses any relevant properties as received by the opened `AudioFileStream`
    ///
    /// - parameter fileStream: An instance of `AudioFileStreamID` that is used to get information from.
    /// - parameter propertyId: A value of `AudioFileStreamPropertyID` indicating the file stream property.
    /// - parameter flags: A value of `UnsafeMutablePointer<AudioFileStreamPropertyFlags>`

    func propertyListenerProc(fileStream: AudioFileStreamID,
                              propertyId: AudioFileStreamPropertyID,
                              flags _: UnsafeMutablePointer<AudioFileStreamPropertyFlags>)
    {
        switch propertyId {
        case kAudioFileStreamProperty_DataOffset:
            processDataOffset(fileStream: fileStream)
        case kAudioFileStreamProperty_FileFormat:
            processFileFormat(fileStream: fileStream)
        case kAudioFileStreamProperty_DataFormat:
            processDataFormat(fileStream: fileStream)
        case kAudioFileStreamProperty_AudioDataByteCount:
            processDataByteCount(fileStream: fileStream)
        case kAudioFileStreamProperty_AudioDataPacketCount:
            proccessAudioDataPacketCount(fileStream: fileStream)
        case kAudioFileStreamProperty_ReadyToProducePackets:
            // check converter for discontious stream
            processReadyToProducePackets(fileStream: fileStream)
        case kAudioFileStreamProperty_FormatList:
            processFormatList(fileStream: fileStream)
        default: break
        }
    }

    // MARK: AudioFileStream properties Proccessing

    private func processDataOffset(fileStream: AudioFileStreamID) {
        var offset: UInt64 = 0
        fileStreamGetProperty(value: &offset, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataOffset)
        playerContext.audioReadingEntry?.audioStreamState.processedDataFormat = true
        playerContext.audioReadingEntry?.audioStreamState.dataOffset = offset
    }

    private func processReadyToProducePackets(fileStream: AudioFileStreamID) {
        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout.size(ofValue: packetCount))
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_AudioDataPacketCount, &packetCountSize, &packetCount)
        playerContext.audioPlayingEntry?.audioStreamState.dataPacketCount = Double(packetCount)
        if playerContext.audioPlayingEntry?.audioStreamFormat.mFormatID != kAudioFormatLinearPCM {
            discontinuous = true
        }
    }

    private func processFileFormat(fileStream: AudioFileStreamID) {
        var fileFormat: [UInt8] = Array(repeating: 0, count: 4)
        var size = UInt32(4)
        AudioFileStreamGetProperty(fileStream, kAudioFileStreamProperty_FileFormat, &size, &fileFormat)
        if let stringFileFormat = String(data: Data(fileFormat), encoding: .utf8) {
            self.fileFormat = stringFileFormat
        }
    }

    private func processDataFormat(fileStream: AudioFileStreamID) {
        var audioStreamFormat = AudioStreamBasicDescription()
        guard let entry = playerContext.audioReadingEntry else { return }
        if !entry.audioStreamState.processedDataFormat {
            fileStreamGetProperty(value: &audioStreamFormat, fileStream: fileStream, propertyId: kAudioFileStreamProperty_DataFormat)

            if entry.audioStreamFormat.mFormatID == 0 {
                entry.audioStreamFormat = audioStreamFormat
            }

            var packetBufferSize: UInt32 = 0
            var status = fileStreamGetProperty(value: &packetBufferSize,
                                               fileStream: fileStream,
                                               propertyId: kAudioFileStreamProperty_PacketSizeUpperBound)
            if status != 0 || packetBufferSize == 0 {
                status = fileStreamGetProperty(value: &packetBufferSize,
                                               fileStream: fileStream,
                                               propertyId: kAudioFileStreamProperty_MaximumPacketSize)
                if status != 0 || packetBufferSize == 0 {
                    packetBufferSize = 2048 // default value
                }
            }
            entry.lock.around {
                entry.processedPacketsState.bufferSize = packetBufferSize
            }

            if fileFormat != fa4mFormat {
                createAudioConverter(from: entry.audioStreamFormat, to: outputAudioFormat)
            }
        }
    }

    private func processDataByteCount(fileStream: AudioFileStreamID) {
        guard let entry = playerContext.audioReadingEntry else { return }
        var audioDataByteCount: UInt64 = 0
        fileStreamGetProperty(value: &audioDataByteCount, fileStream: fileStream, propertyId: kAudioFileStreamProperty_AudioDataByteCount)
        entry.audioStreamState.dataByteCount = audioDataByteCount
    }

    private func proccessAudioDataPacketCount(fileStream: AudioFileStreamID) {
        guard let entry = playerContext.audioReadingEntry else { return }
        var audioDataPacketCount: UInt64 = 0
        fileStreamGetProperty(value: &audioDataPacketCount, fileStream: fileStream, propertyId: kAudioFileStreamProperty_AudioDataPacketCount)
        entry.audioStreamState.dataPacketOffset = audioDataPacketCount
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
            let asbd = list[i].mASBD
            let formatId = asbd.mFormatID
            if formatId == kAudioFormatMPEG4AAC_HE || formatId == kAudioFormatMPEG4AAC_HE_V2 {
                playerContext.audioReadingEntry?.audioStreamFormat = asbd
                break
            }
            i += step
        }

        if fileFormat == fa4mFormat {
            if let inputStreamFormat = playerContext.audioReadingEntry?.audioStreamFormat {
                createAudioConverter(from: inputStreamFormat, to: outputAudioFormat)
            }
        }
    }

    // MARK: Packets Proc

    func propertyPacketsProc(inNumberBytes: UInt32,
                             inNumberPackets: UInt32,
                             inInputData: UnsafeRawPointer,
                             inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?)
    {
        guard let entry = playerContext.audioReadingEntry else { return }
        guard entry.audioStreamState.processedDataFormat, !playerContext.disposedRequested else { return }

        if let playingEntry = playerContext.audioPlayingEntry,
           playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
        {
            fileStreamCallback?(.proccessSource)
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
            return
        }

        guard let converter = audioConverter else {
            Logger.error("Couldn't find audio converter", category: .audioRendering)
            return
        }

        // reset discontinuity
        discontinuous = false

        var convertInfo = AudioConvertInfo(done: false,
                                           numberOfPackets: inNumberPackets,
                                           packDescription: inPacketDescriptions)
        convertInfo.audioBuffer.mData = UnsafeMutableRawPointer(mutating: inInputData)
        convertInfo.audioBuffer.mDataByteSize = inNumberBytes
        if let playingAudioStreamFormat = playerContext.audioPlayingEntry?.audioStreamFormat {
            convertInfo.audioBuffer.mNumberChannels = playingAudioStreamFormat.mChannelsPerFrame
        }

        updateProccessedPackets(inPacketDescriptions: inPacketDescriptions,
                                inNumberPackets: inNumberPackets)

        var status: OSStatus = noErr
        packetProccess: while status == noErr {
            rendererContext.lock.lock()
            let bufferContext = rendererContext.bufferContext
            var used = bufferContext.frameUsedCount
            var start = bufferContext.frameStartIndex
            var end = bufferContext.end

            var framesLeftInBuffer = bufferContext.totalFrameCount - used
            rendererContext.lock.unlock()

            if framesLeftInBuffer == 0 {
                while true {
                    rendererContext.lock.lock()
                    let bufferContext = rendererContext.bufferContext
                    used = bufferContext.frameUsedCount
                    start = bufferContext.frameStartIndex
                    end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount
                    framesLeftInBuffer = bufferContext.totalFrameCount - used
                    rendererContext.lock.unlock()
                    if framesLeftInBuffer > 0 {
                        break
                    }
                    if playerContext.disposedRequested
                        || playerContext.internalState == .disposed
                        || playerContext.internalState == .pendingNext
                        || playerContext.internalState == .stopped
                    {
                        return
                    }

                    if let playingEntry = playerContext.audioPlayingEntry,
                       playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0
                    {
                        fileStreamCallback?(.proccessSource)
                        if rendererContext.waiting.value {
                            rendererContext.packetsSemaphore.signal()
                        }
                        return
                    }

                    rendererContext.waiting.write { $0 = true }
                    rendererContext.packetsSemaphore.wait()
                    rendererContext.waiting.write { $0 = false }
                }
            }

            let localBufferList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { localBufferList.unsafeMutablePointer.deallocate() }

            if end >= start {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = rendererContext.bufferContext.totalFrameCount - end

                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(bufferList: localBufferList,
                                       dataOffset: offset,
                                       framesToDecode: framesToDecode)

                status = AudioConverterFillComplexBuffer(converter,
                                                         _converterCallback,
                                                         &convertInfo,
                                                         &framesToDecode,
                                                         localBufferList.unsafeMutablePointer,
                                                         nil)

                framesAdded = framesToDecode

                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }

                framesToDecode = start
                if framesToDecode == 0 {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                }
                prefillLocalBufferList(bufferList: localBufferList,
                                       dataOffset: 0,
                                       framesToDecode: framesToDecode)

                status = AudioConverterFillComplexBuffer(converter,
                                                         _converterCallback,
                                                         &convertInfo,
                                                         &framesToDecode,
                                                         localBufferList.unsafeMutablePointer,
                                                         nil)

                framesAdded += framesToDecode

                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.proccessed.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }
            } else {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = start - end

                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(bufferList: localBufferList,
                                       dataOffset: offset,
                                       framesToDecode: framesToDecode)

                status = AudioConverterFillComplexBuffer(converter,
                                                         _converterCallback,
                                                         &convertInfo,
                                                         &framesToDecode,
                                                         localBufferList.unsafeMutablePointer,
                                                         nil)

                framesAdded = framesToDecode
                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.proccessed.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProccess
                } else if status != 0 {
                    fileStreamCallback?(.raiseError(.codecError))
                    return
                }
            }
        }
    }

    /// Fills the `AudioBuffer` with data as required
    ///
    /// - parameter list: An `UnsafeMutableAudioBufferListPointer` object representing the buffer list be filled with data
    /// - parameter dataOffset: An `Int` value indicating any offset to be applied to the buffer data
    /// - parameter framesToDecode: An `UInt32` value indicating the frames to be decoded, used in calculating the data size of the buffer.
    @inline(__always)
    private func prefillLocalBufferList(bufferList: UnsafeMutableAudioBufferListPointer,
                                        dataOffset: Int,
                                        framesToDecode: UInt32)
    {
        if let mData = rendererContext.audioBuffer.mData {
            bufferList[0].mData = dataOffset > 0 ? mData + dataOffset : mData
        }
        bufferList[0].mDataByteSize = framesToDecode * rendererContext.bufferContext.sizeInBytes
        bufferList[0].mNumberChannels = rendererContext.audioBuffer.mNumberChannels
    }

    /// Advances the processed frames for buffer and reading entry
    ///
    /// - parameter frameCount: An `UInt32` value to be added to the used count of the buffers.
    @inline(__always)
    private func fillUsedFrames(framesCount: UInt32) {
        rendererContext.lock.lock()
        rendererContext.bufferContext.frameUsedCount += framesCount
        rendererContext.lock.unlock()

        playerContext.audioReadingEntry?.lock.lock()
        playerContext.audioReadingEntry?.framesState.queued += Int(framesCount)
        playerContext.audioReadingEntry?.lock.unlock()
    }

    @inline(__always)
    private func updateProccessedPackets(inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?,
                                         inNumberPackets: UInt32)
    {
        guard let inPacketDescriptions = inPacketDescriptions else { return }
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        let processedPackCount = readingEntry.processedPacketsState.count
        if processedPackCount < maxCompressedPacketForBitrate {
            let count = min(Int(inNumberPackets), maxCompressedPacketForBitrate - Int(processedPackCount))
            for i in 0 ..< count {
                let packet = inPacketDescriptions[i]
                let packetSize: UInt32 = packet.mDataByteSize
                readingEntry.lock.lock()
                readingEntry.processedPacketsState.sizeTotal += packetSize
                readingEntry.processedPacketsState.count += 1
                readingEntry.lock.unlock()
            }
        }
    }
}

// MARK: - AudioFileStream proc method

private func _propertyListenerProc(clientData: UnsafeMutableRawPointer,
                                   fileStream: AudioFileStreamID,
                                   propertyId: AudioFileStreamPropertyID,
                                   flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>)
{
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyListenerProc(fileStream: fileStream,
                                   propertyId: propertyId,
                                   flags: flags)
}

private func _propertyPacketsProc(clientData: UnsafeMutableRawPointer,
                                  inNumberBytes: UInt32,
                                  inNumberPackets: UInt32,
                                  inInputData: UnsafeRawPointer,
                                  inPacketDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?)
{
    let processor = clientData.to(type: AudioFileStreamProcessor.self)
    processor.propertyPacketsProc(inNumberBytes: inNumberBytes,
                                  inNumberPackets: inNumberPackets,
                                  inInputData: inInputData,
                                  inPacketDescriptions: inPacketDescriptions)
}

// MARK: - AudioConverterFillComplexBuffer callback method

private func _converterCallback(inAudioConverter _: AudioConverterRef,
                                ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
                                ioData: UnsafeMutablePointer<AudioBufferList>,
                                outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                                inUserData: UnsafeMutableRawPointer?) -> OSStatus
{
    guard let convertInfo = inUserData?.assumingMemoryBound(to: AudioConvertInfo.self) else { return 0 }

    // we need to tell the converter to stop converting after it should stop converting
    if convertInfo.pointee.done {
        ioNumberDataPackets.pointee = 0
        return AudioConvertStatus.done.rawValue
    }
    // calculate the input buffer
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = convertInfo.pointee.audioBuffer

    // output the packet descriptions
    if outDataPacketDescription != nil {
        outDataPacketDescription?.pointee = convertInfo.pointee.packDescription
    }

    ioNumberDataPackets.pointee = convertInfo.pointee.numberOfPackets
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

        for item in encoderDescriptions where item.mManufacturer == kAppleHardwareAudioCodecManufacturer {
            classDesc.pointee = item
            return true
        }
    #endif
    return false
}
