//
//  OggVorbisStreamProcessor.swift
//  AudioStreaming
//
//  Created on 25/10/2025.
//

import Foundation
import AVFoundation
import CoreAudio

/// A processor for Ogg Vorbis audio streams
final class OggVorbisStreamProcessor {
    /// The callback to notify when processing is complete or an error occurs
    var processorCallback: ((FileStreamProcessorEffect) -> Void)?
    
    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription
    
    private var decoder: OggVorbisDecoder?
    private var discontinuous: Bool = false
    private var isInitialized: Bool = false
    private let vfDecoder = VorbisFileDecoder()
    private var vfCreated = false
    private var vfOpened = false
    
    // Audio converter for converting from Ogg Vorbis to the output format
    private var audioConverter: AudioConverterRef?
    
    // Store the input format to check if we need to recreate the converter
    private var inputFormat = AudioStreamBasicDescription()
    
    // MARK: - AudioConverterFillComplexBuffer callback method
    
    /// The callback function for AudioConverterFillComplexBuffer
    private let _converterCallback: AudioConverterComplexInputDataProc = { (
        _: AudioConverterRef,
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
        inUserData: UnsafeMutableRawPointer?
    ) -> OSStatus in
        guard let convertInfo = inUserData?.assumingMemoryBound(to: AudioConvertInfo.self) else { return 0 }

        // If we're done, return
        if convertInfo.pointee.done {
            ioNumberDataPackets.pointee = 0
            return AudioConvertStatus.done.rawValue
        }
        
        // For interleaved audio, we just need to set up a single buffer
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)
        
        // For interleaved format, we just fill the first buffer with all our data
        if bufferList.count > 0 {
            bufferList[0] = convertInfo.pointee.audioBuffer
            
            // For debugging
            print("Converter callback: Filling buffer with \(convertInfo.pointee.audioBuffer.mDataByteSize) bytes of data, \(convertInfo.pointee.audioBuffer.mNumberChannels) channels")
        }

        // Set the packet descriptions if needed
        if outDataPacketDescription != nil {
            outDataPacketDescription?.pointee = convertInfo.pointee.packDescription
        }
        
        // For PCM data, each frame is a packet
        // The number of packets is the number of frames (not the total samples)
        let audioBuffer = convertInfo.pointee.audioBuffer
        let bytesPerFrame = audioBuffer.mDataByteSize / audioBuffer.mNumberChannels
        let framesAvailable = audioBuffer.mDataByteSize / bytesPerFrame
        
        // Provide as many packets as we have, up to the requested amount
        let requestedPackets = ioNumberDataPackets.pointee
        let packetsToProvide = min(requestedPackets, framesAvailable)
        ioNumberDataPackets.pointee = packetsToProvide
        
        print("Converter callback: Requested \(requestedPackets) packets, providing \(packetsToProvide) packets (frames: \(framesAvailable))")
        
        // Mark as done so we don't process the same data again
        convertInfo.pointee.done = true

        return noErr
    }
    
    /// Initialize the OggVorbisStreamProcessor
    /// - Parameters:
    ///   - playerContext: The audio player context
    ///   - rendererContext: The audio renderer context
    ///   - outputAudioFormat: The output audio format
    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription) {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
        self.decoder = OggVorbisDecoder()
    }
    
    deinit {
        disposeAudioConverter()
    }
    
    /// Parse Ogg Vorbis data
    /// - Parameter data: The Ogg Vorbis data to parse
    /// - Returns: An OSStatus indicating success or failure
    // Maximum number of bytes to process in a single call
    private let maxBytesToProcessAtOnce: Int = 8192 // 8KB
    
    // Maximum buffer fill percentage before forcing a wait
    private let maxBufferFillPercentage: Double = 0.5 // 50%
    
    func parseOggVorbisData(data: Data) -> OSStatus {
        guard playerContext.audioReadingEntry != nil else { return 0 }
        
        // Always process data directly - chunking was causing issues with audio continuity
        return parseOggVorbisDataChunk(data: data)
    }
    
    private func parseOggVorbisDataChunk(data: Data) -> OSStatus {
        guard let entry = playerContext.audioReadingEntry else { return 0 }
        
        // Initialize vorbisfile ring buffer once and push incoming bytes
        if !vfCreated {
            // 2MB ring buffer for better streaming
            vfDecoder.create(capacityBytes: 2_097_152)
            vfCreated = true
        }
        vfDecoder.push(data)
        
        // Phase 1: Initialize the decoder and set up the audio format if needed
        if !isInitialized {
            entry.lock.lock()
            if var initialBytes = entry.audioStreamState.initialOggBytes {
                initialBytes.append(data)
                entry.audioStreamState.initialOggBytes = initialBytes
            } else {
                entry.audioStreamState.initialOggBytes = data
            }
            entry.lock.unlock()
            
            // Try to open vorbisfile when enough headers have arrived
            do {
                if !vfOpened {
                    try vfDecoder.openIfNeeded()
                    vfOpened = true
                    isInitialized = true
                    // Set up audio format once
                    print("OggVorbisStreamProcessor: VorbisFile opened successfully - Sample rate: \(vfDecoder.sampleRate), Channels: \(vfDecoder.channels), Duration: \(vfDecoder.durationSeconds)")
                    setupAudioFormat(sampleRate: vfDecoder.sampleRate, channels: vfDecoder.channels)
                    return noErr
                }
            } catch {
                // Need more data; continue accumulating
                return noErr
            }
        }
        
        // If not initialized yet, just return success without error
        // This ensures we don't trigger an error state on the first few packets
        guard isInitialized else { 
            // Don't report an error, just wait for more data
            return noErr 
        }
        
        // Handle seek requests
        if let playingEntry = playerContext.audioPlayingEntry,
           playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0 {
            processorCallback?(.processSource)
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
            return noErr
        }
        
        // Reset discontinuity flag
        discontinuous = false
        
        // Process decoded frames from vorbisfile using SFBAudioEngine approach
        guard let processingFormat = vfDecoder.processingFormat else { return noErr }
        
        // Create PCM buffer with non-interleaved format (like SFBAudioEngine)
        // Use larger frame count for better streaming performance
        let frameCount = 1024
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: UInt32(frameCount)) else {
            Logger.error("Failed to create PCM buffer", category: .audioRendering)
            return noErr
        }
        
        // Read frames directly into AVAudioPCMBuffer (non-interleaved)
        let framesRead = vfDecoder.readFrames(into: pcmBuffer, frameCount: frameCount)
        if framesRead <= 0 { return noErr }
        pcmBuffer.frameLength = UInt32(framesRead)
        
        // Convert AVAudioPCMBuffer to AudioBuffer for our system
        let buffer = createAudioBufferFromPCMBuffer(pcmBuffer)
        
        // Make sure we have a valid audio format set up
        if !entry.audioStreamState.processedDataFormat || !entry.audioStreamState.readyForDecoding {
            // If we got here, the decoder is initialized but the audio format wasn't properly set
            // Use the vfDecoder's processing format
            if vfDecoder.processingFormat != nil {
                print("OggVorbisStreamProcessor: Setting up audio format from vfDecoder")
                setupAudioFormat(sampleRate: vfDecoder.sampleRate, channels: vfDecoder.channels)
                
                // Explicitly set these flags
                entry.lock.lock()
                entry.audioStreamState.processedDataFormat = true
                entry.audioStreamState.readyForDecoding = true
                entry.lock.unlock()
            }
        }
        
        // Calculate frames/packets
        let numFrames = UInt32(framesRead)
        
        print("OggVorbisStreamProcessor: PCM frames: \(framesRead), Channels: \(pcmBuffer.format.channelCount)")
        
        // For PCM audio, each frame is a packet (standard for PCM)
        // But we need to be careful with the buffer size and channels
        let bytesPerSample = 4 // Float32 = 4 bytes
        let numberOfPackets = UInt32(framesRead) // One packet per frame for PCM
        
        print("OggVorbisStreamProcessor: Frames: \(numFrames), Packets: \(numberOfPackets), Buffer size: \(buffer.mDataByteSize), Bytes per frame: \(bytesPerSample * Int(pcmBuffer.format.channelCount))")
        
        // We'll use nil for packet descriptions since we're using constant frame size PCM
        var convertInfo = AudioConvertInfo(
            done: false,
            numberOfPackets: numberOfPackets,
            packDescription: nil
        )
        convertInfo.audioBuffer = buffer
        
        // Update processed packets
        updateProcessedPackets(inNumberPackets: convertInfo.numberOfPackets)
        
        // Fill the buffer with decoded audio
        fillBufferWithDecodedAudio(convertInfo: &convertInfo)
        
        return noErr
    }

    // Helper: convert AVAudioPCMBuffer to AudioBuffer
    private func createAudioBufferFromPCMBuffer(_ pcmBuffer: AVAudioPCMBuffer) -> AudioBuffer {
        var buffer = AudioBuffer()
        let channels = Int(pcmBuffer.format.channelCount)
        let frames = Int(pcmBuffer.frameLength)
        
        // Create interleaved buffer from non-interleaved PCM buffer
        let interleavedSize = frames * channels
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: interleavedSize)
        
        // Get float channel data from buffer
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            // Fallback if we can't get float data
            buffer.mNumberChannels = UInt32(channels)
            buffer.mDataByteSize = 0
            buffer.mData = UnsafeMutableRawPointer(ptr)
            return buffer
        }
        
        // Interleave the data
        for frame in 0..<frames {
            for ch in 0..<channels {
                ptr[frame * channels + ch] = floatChannelData[ch][frame]
            }
        }
        
        buffer.mNumberChannels = UInt32(channels)
        buffer.mDataByteSize = UInt32(interleavedSize * MemoryLayout<Float>.size)
        buffer.mData = UnsafeMutableRawPointer(ptr)
        
        return buffer
    }

    // Setup audio format using the processingFormat from VorbisFileDecoder
    private func setupAudioFormat(sampleRate: Int, channels: Int) {
        guard let entry = playerContext.audioReadingEntry, 
              let processingFormat = vfDecoder.processingFormat else { return }
        
        entry.lock.lock()
        
        // Get the AudioStreamBasicDescription directly from the AVAudioFormat
        // This ensures we're using the exact same format that SFBAudioEngine would use
        let asbd = processingFormat.streamDescription.pointee
        
        // Store the format in the entry
        entry.audioStreamFormat = asbd
        entry.sampleRate = Float(sampleRate)
        
        // Set packet duration for proper playback speed
        // Critical: For PCM audio, each frame is one sample per channel
        // We need to ensure the duration matches what AVAudioEngine expects
        let framesPerPacket = 1
        entry.packetDuration = Double(framesPerPacket) / Double(sampleRate)
        
        // Set stream info
        if vfDecoder.totalPcmSamples > 0 {
            entry.audioStreamState.dataPacketCount = Double(vfDecoder.totalPcmSamples)
        }
        
        // Set bitrate estimate if available (helps with seeking)
        entry.audioStreamState.bitRate = 128000 // Default to 128kbps for Ogg
        
        print("OggVorbisStreamProcessor: Using processingFormat: \(processingFormat)")
        print("OggVorbisStreamProcessor: Setting packet duration: \(entry.packetDuration) seconds")
        
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.lock.unlock()
        
        // Use the processingFormat's ASBD directly for the audio converter
        self.inputFormat = asbd
        createAudioConverter(from: asbd, to: outputAudioFormat)
    }
    
    /// Process a seek request
    func processSeek() {
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        
        guard readingEntry.calculatedBitrate() > 0.0 || (playerContext.audioPlayingEntry?.length ?? 0) > 0 else {
            return
        }
        
        let dataOffset = Double(readingEntry.audioStreamState.dataOffset)
        let dataLengthInBytes = Double(readingEntry.audioDataLengthBytes())
        let entryDuration = readingEntry.duration()
        let duration = entryDuration < readingEntry.progress && entryDuration > 0 ? readingEntry.progress : entryDuration
        
        guard duration > 0.0 else { return }
        
        var seekByteOffset = Int64(dataOffset + (readingEntry.seekRequest.time / duration) * dataLengthInBytes)
        
        if seekByteOffset > readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)) {
            seekByteOffset = Int64(readingEntry.length - (2 * Int(readingEntry.processedPacketsState.bufferSize)))
        }
        
        readingEntry.lock.lock()
        readingEntry.seekTime = readingEntry.seekRequest.time
        readingEntry.lock.unlock()
        
        // Reset the decoder
        do {
            try decoder?.reset()
            isInitialized = false
            
            // Clear initial bytes to force reinitialization
            readingEntry.lock.lock()
            readingEntry.audioStreamState.initialOggBytes = nil
            readingEntry.audioStreamState.hasAttemptedOggVorbisParse = false
            readingEntry.lock.unlock()
            
        } catch {
            Logger.error("Error resetting Ogg Vorbis decoder: %@", category: .audioRendering, args: error.localizedDescription)
            processorCallback?(.raiseError(.audioSystemError(.codecError)))
            return
        }
        
        readingEntry.reset()
        readingEntry.seek(at: Int(seekByteOffset))
        rendererContext.waitingForDataAfterSeekFrameCount.write { $0 = 0 }
        playerContext.setInternalState(to: .waitingForDataAfterSeek)
        rendererContext.resetBuffers()
    }
    
    /// Disposes the audio converter if it exists
    private func disposeAudioConverter() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
    }
    
    /// Creates an AudioConverter for converting from the source format to the output format
    /// - Parameters:
    ///   - fromFormat: The source audio format
    ///   - toFormat: The output audio format

    private func createAudioConverter(from fromFormat: AudioStreamBasicDescription, to toFormat: AudioStreamBasicDescription) {
        guard let entry = playerContext.audioReadingEntry else { return }
        
        // Check if we already have a converter
        var inputFormatCopy = fromFormat
        if let converter = audioConverter {
            // If the format is the same, just reset the converter and return
            if memcmp(&inputFormatCopy, &self.inputFormat, MemoryLayout<AudioStreamBasicDescription>.size) == 0 {
                AudioConverterReset(converter)
                
                entry.lock.lock()
                entry.audioStreamState.processedDataFormat = true
                entry.audioStreamState.readyForDecoding = true
                entry.lock.unlock()
                return
            }
            // Otherwise, dispose of the old converter and create a new one
            disposeAudioConverter()
        }
        
        // Verify that the source format is valid
        if fromFormat.mSampleRate == 0 || fromFormat.mChannelsPerFrame == 0 {
            Logger.error("Invalid source format for audio converter: sampleRate=%f, channels=%d", 
                        category: .audioRendering, 
                        args: fromFormat.mSampleRate, fromFormat.mChannelsPerFrame)
            processorCallback?(.raiseError(.audioSystemError(.converterError(.cannotCreateConverter))))
            return
        }
        
        // Create a simple audio converter for PCM to PCM conversion
        var sourceFormat = fromFormat
        var destinationFormat = toFormat
        
        print("OggVorbisStreamProcessor: Creating audio converter from \(sourceFormat.mSampleRate) Hz, \(sourceFormat.mChannelsPerFrame) channels to \(destinationFormat.mSampleRate) Hz, \(destinationFormat.mChannelsPerFrame) channels")
        
        var audioConverter: AudioConverterRef?
        let status = AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)
        
        if status != noErr {
            Logger.error("Failed to create audio converter: %d", category: .audioRendering, args: status)
            processorCallback?(.raiseError(.audioSystemError(.converterError(.cannotCreateConverter))))
            return
        }
        
        // Store the audio converter and input format
        self.audioConverter = audioConverter
        self.inputFormat = fromFormat
        
        entry.lock.lock()
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.lock.unlock()
    }
    
    /// Set up the audio format and create the audio converter
    /// - Parameter decoderInfo: The decoder stream info
    private func setupAudioFormat(with decoderInfo: OggVorbisStreamData) {
        guard let entry = playerContext.audioReadingEntry else { return }
        
        entry.lock.lock()
        
        // Convert from OggVorbisStreamData to OggVorbisStreamInfo
        let oggInfo = decoderInfo.toOggVorbisStreamInfo()
        entry.audioStreamState.oggVorbisStreamInfo = oggInfo
        
        // Create a standard PCM format
        var audioFormat = AudioStreamBasicDescription()
//        audioFormat.mSampleRate = Float64(decoderInfo.sampleRate)
//        audioFormat.mFormatID = kAudioFormatLinearPCM
//        audioFormat.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
//        
//        // For interleaved audio, bytes per frame = channels * bytes per sample
        let bytesPerSample = MemoryLayout<Float>.size
//        let framesPerPacket: UInt32 = 1 // Standard for PCM
//
//        
//
//        audioFormat.mFramesPerPacket = framesPerPacket
//        audioFormat.mBytesPerFrame = UInt32(Int(decoderInfo.channels) * bytesPerSample)
//        audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame
//        audioFormat.mChannelsPerFrame = UInt32(decoderInfo.channels)
//        audioFormat.mBitsPerChannel = UInt32(8 * bytesPerSample)

        // Note: We're using a simple PCM format and don't need channel layout
        
        // Create a standard PCM format manually (don't rely on AVAudioFormat which can change)
        audioFormat.mSampleRate = Float64(decoderInfo.sampleRate)
        audioFormat.mFormatID = kAudioFormatLinearPCM
        audioFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        audioFormat.mBitsPerChannel = 32
        audioFormat.mChannelsPerFrame = UInt32(decoderInfo.channels)
        audioFormat.mFramesPerPacket = 1  // Standard for PCM
        audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * 4  // 4 bytes per float
        audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame

        print("OggVorbisStreamProcessor: Creating audio format - Sample rate: \(decoderInfo.sampleRate), Channels: \(decoderInfo.channels), Bytes per sample: \(bytesPerSample)")
        print("OggVorbisStreamProcessor: Setting audio format - Format flags: \(audioFormat.mFormatFlags), Bytes per packet: \(audioFormat.mBytesPerPacket), Bytes per frame: \(audioFormat.mBytesPerFrame)")
        
        entry.audioStreamFormat = audioFormat
        entry.sampleRate = Float(decoderInfo.sampleRate)
        
        // Calculate packet duration based on frames per packet
        // Use a slightly larger value to slow down playback a bit
        entry.packetDuration = Double(audioFormat.mFramesPerPacket) / Double(decoderInfo.sampleRate) * 1.5
        
        print("OggVorbisStreamProcessor: Setting packet duration: \(entry.packetDuration) seconds (frames per packet: \(audioFormat.mFramesPerPacket))")
        
        // Set stream info
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.audioStreamState.dataPacketCount = Double(decoderInfo.totalSamples)
        entry.audioStreamState.bitRate = Double(decoderInfo.bitRate * 1000)
        
        entry.lock.unlock()
        
        // Store the input format and create audio converter (only once)
        self.inputFormat = audioFormat
        createAudioConverter(from: audioFormat, to: outputAudioFormat)
    }
    
    /// Update the processed packets information
    /// - Parameter inNumberPackets: The number of packets processed
    private func updateProcessedPackets(inNumberPackets: UInt32) {
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        let processedPackCount = readingEntry.processedPacketsState.count
        let maxPackets = 4096 // Same as maxCompressedPacketForBitrate in AudioFileStreamProcessor
        
        if processedPackCount < maxPackets {
            let count = min(Int(inNumberPackets), maxPackets - Int(processedPackCount))
            let packetSize: UInt32 = UInt32(readingEntry.audioStreamFormat.mBytesPerFrame)
            
            readingEntry.lock.lock()
            readingEntry.processedPacketsState.sizeTotal += (packetSize * UInt32(count))
            readingEntry.processedPacketsState.count += UInt32(count)
            readingEntry.lock.unlock()
        }
    }
    
    /// Fill the buffer with decoded audio
    /// - Parameter convertInfo: The audio conversion info
    private func fillBufferWithDecodedAudio(convertInfo: inout AudioConvertInfo) {
        guard let converter = audioConverter else {
            Logger.error("Audio converter not available", category: .audioRendering)
            processorCallback?(.raiseError(.audioSystemError(.converterError(.cannotCreateConverter))))
            return
        }
        
        var status: OSStatus = noErr
        
        packetProcess: while status == noErr {
            rendererContext.lock.lock()
            let bufferContext = rendererContext.bufferContext
            var used = bufferContext.frameUsedCount
            var start = bufferContext.frameStartIndex
            var end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount
            
            var framesLeftInBuffer = bufferContext.totalFrameCount - used
            rendererContext.lock.unlock()
            
            // Debug buffer state
            let fillPercentage = Double(used) / Double(bufferContext.totalFrameCount)
            print("OggVorbisStreamProcessor: Buffer state - Used: \(used), Total: \(bufferContext.totalFrameCount), Left: \(framesLeftInBuffer), Fill: \(Int(fillPercentage * 100))%")
            
            // Force wait if buffer is getting too full (to ensure we trigger the semaphore mechanism)
            if framesLeftInBuffer == 0 || fillPercentage > maxBufferFillPercentage {
                print("OggVorbisStreamProcessor: Buffer is full, waiting for space")
                while true {
                    rendererContext.lock.lock()
                    let bufferContext = rendererContext.bufferContext
                    used = bufferContext.frameUsedCount
                    start = bufferContext.frameStartIndex
                    end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount
                    framesLeftInBuffer = bufferContext.totalFrameCount - used
                    rendererContext.lock.unlock()
                    
                    let currentFillPercentage = Double(used) / Double(bufferContext.totalFrameCount)
                    print("OggVorbisStreamProcessor: Checking buffer - Used: \(used), Total: \(bufferContext.totalFrameCount), Left: \(framesLeftInBuffer), Fill: \(Int(currentFillPercentage * 100))%")
                    
                    // Continue if buffer is below threshold
                    if framesLeftInBuffer > 0 && currentFillPercentage < maxBufferFillPercentage {
                        break
                    }
                    
                    if playerContext.internalState == .disposed
                        || playerContext.internalState == .pendingNext
                        || playerContext.internalState == .stopped {
                        return
                    }
                    
                    if let playingEntry = playerContext.audioPlayingEntry,
                       playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0 {
                        processorCallback?(.processSource)
                        if rendererContext.waiting.value {
                            rendererContext.packetsSemaphore.signal()
                        }
                        return
                    }
                    
                    // Wait for the renderer to process data
                    print("OggVorbisStreamProcessor: ⏳ WAITING for renderer to process data")
                    rendererContext.waiting.write { $0 = true }
                    
                    // Add a timeout to the semaphore wait to prevent deadlocks
                    let waitResult = rendererContext.packetsSemaphore.wait(timeout: .now() + 1.0) // 1 second timeout
                    
                    if waitResult == .timedOut {
                        print("OggVorbisStreamProcessor: ⚠️ Wait TIMED OUT after 1 second!")
                        // If we time out, we should break out of the wait loop
                        rendererContext.waiting.write { $0 = false }
                        break
                    } else {
                        rendererContext.waiting.write { $0 = false }
                        print("OggVorbisStreamProcessor: ✅ Renderer SIGNALED, continuing")
                    }
                }
            }
            
            let localBufferList = AudioBufferList.allocate(maximumBuffers: 1)
            defer { localBufferList.unsafeMutablePointer.deallocate() }
            
            if end >= start {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = rendererContext.bufferContext.totalFrameCount - end
                
                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: offset,
                    framesToDecode: framesToDecode
                )
                
                // Use the audio converter to convert the data
                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )
                
                framesAdded = framesToDecode
                
                if framesAdded > 0 {
                    fillUsedFrames(framesCount: framesAdded)
                }
                
                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status != 0 {
                    processorCallback?(.raiseError(.audioSystemError(.codecError)))
                    return
                }
                
                framesToDecode = start
                if framesToDecode == 0 {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                }
                
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: 0,
                    framesToDecode: framesToDecode
                )
                
                // Use the audio converter to convert the remaining data
                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )
                
                framesAdded += framesToDecode
                
                if status == AudioConvertStatus.done.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    return
                } else if status == AudioConvertStatus.processed.rawValue {
                    fillUsedFrames(framesCount: framesAdded)
                    continue packetProcess
                } else if status != 0 {
                    processorCallback?(.raiseError(.audioSystemError(.codecError)))
                    return
                }
                
            } else {
                var framesAdded: UInt32 = 0
                var framesToDecode: UInt32 = start - end
                
                let offset = Int(end * rendererContext.bufferContext.sizeInBytes)
                prefillLocalBufferList(
                    bufferList: localBufferList,
                    dataOffset: offset,
                    framesToDecode: framesToDecode
                )
                
                // Use the audio converter to convert the data
                status = AudioConverterFillComplexBuffer(
                    converter,
                    _converterCallback,
                    &convertInfo,
                    &framesToDecode,
                    localBufferList.unsafeMutablePointer,
                    nil
                )
                
                framesAdded = framesToDecode
                
                if framesAdded > 0 {
                    fillUsedFrames(framesCount: framesAdded)
                }
                
                if status == AudioConvertStatus.done.rawValue {
                    return
                } else if status == AudioConvertStatus.processed.rawValue {
                    continue packetProcess
                } else if status != 0 {
                    processorCallback?(.raiseError(.audioSystemError(.codecError)))
                    return
                }
            }
        }
    }
    
    /// Fills the AudioBuffer with data as required
    /// - Parameters:
    ///   - bufferList: The audio buffer list to fill
    ///   - dataOffset: The offset in the data
    ///   - framesToDecode: The number of frames to decode
    @inline(__always)
    private func prefillLocalBufferList(
        bufferList: UnsafeMutableAudioBufferListPointer,
        dataOffset: Int,
        framesToDecode: UInt32
    ) {
        if let mData = rendererContext.audioBuffer.mData {
            bufferList[0].mData = dataOffset > 0 ? mData + dataOffset : mData
        }
        bufferList[0].mDataByteSize = framesToDecode * rendererContext.bufferContext.sizeInBytes
        bufferList[0].mNumberChannels = rendererContext.audioBuffer.mNumberChannels
    }
    
    /// Advances the processed frames for buffer and reading entry
    /// - Parameter frameCount: The number of frames to advance
    @inline(__always)
    private func fillUsedFrames(framesCount: UInt32) {
        rendererContext.lock.lock()
        rendererContext.bufferContext.frameUsedCount += framesCount
        rendererContext.lock.unlock()
        
        playerContext.audioReadingEntry?.lock.lock()
        playerContext.audioReadingEntry?.framesState.queued += Int(framesCount)
        playerContext.audioReadingEntry?.lock.unlock()
    }
}
