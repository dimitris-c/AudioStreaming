//
//  OggVorbisStreamProcessor.swift
//  AudioStreaming
//
//  Created on 25/10/2025.
//

import Foundation
import AVFoundation
import CoreAudio

/// Info for AudioConverter callback
struct OggVorbisConvertInfo {
    var done: Bool
    let numberOfFrames: UInt32
    var audioBuffer = AudioBuffer()
}

/// A processor for Ogg Vorbis audio streams using libvorbisfile
final class OggVorbisStreamProcessor {
    /// The callback to notify when processing is complete or an error occurs
    var processorCallback: ((FileStreamProcessorEffect) -> Void)?
    
    // MARK: - Constants
    
    /// Correction factor for Ogg container overhead in bitrate-based duration calculation.
    /// Ogg containers add 3-4% overhead (page headers, packet headers, metadata).
    /// The nominal bitrate only accounts for audio data, not container overhead.
    /// By reducing the bitrate slightly, we increase the calculated duration to match reality.
    private let oggContainerOverheadFactor: Double = 0.96  // 4% overhead
    
    /// Fallback bitrate estimates when nominal bitrate is unavailable
    private let fallbackBitrateStereo: Double = 160_000  // 160 kbps for stereo
    private let fallbackBitrateMono: Double = 96_000     // 96 kbps for mono
    
    // MARK: - Properties
    
    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription
    
    private let vfDecoder = VorbisFileDecoder()
    private var isInitialized = false
    
    // Audio converter for format conversion
    private var audioConverter: AudioConverterRef?
    private var inputFormat = AudioStreamBasicDescription()
    
    // Buffer for PCM conversion
    private var pcmBuffer: AVAudioPCMBuffer?
    private let frameCount = 1024
    
    // Seeking state (currently unused - seeking not fully supported)
    // Future enhancement: implement proper seeking for local files
    
    // Debug logging
    private var totalFramesProcessed = 0
    private var dataChunkCount = 0
    
    // MARK: - Initialization
    
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
    }
    
    deinit {
        cleanup()
    }
    
    /// Clean up all resources and reset state
    func cleanup() {
        cleanupBuffers()
        
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        
        // Destroy and reset the decoder
        vfDecoder.destroy()
        isInitialized = false
        totalFramesProcessed = 0
    }
    
    // MARK: - Data Processing
    
    /// Parse Ogg Vorbis data
    /// - Parameter data: The Ogg Vorbis data to parse
    /// - Returns: An OSStatus indicating success or failure
    func parseOggVorbisData(data: Data) -> OSStatus {
        guard let entry = playerContext.audioReadingEntry else { return 0 }
        
        dataChunkCount += 1
        
        if !isInitialized {
            vfDecoder.create(capacityBytes: 2_097_152)
            isInitialized = true
            totalFramesProcessed = 0
        }
        
        vfDecoder.push(data)
        
        if !entry.audioStreamState.processedDataFormat {
            let availableBytes = vfDecoder.availableBytes()
            
            if availableBytes >= 16384 {
                do {
                    try vfDecoder.openIfNeeded()
                    
                    if vfDecoder.sampleRate > 0 && vfDecoder.channels > 0 {
                        setupAudioFormat()
                        
                        if pcmBuffer == nil, let processingFormat = vfDecoder.processingFormat {
                            pcmBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: UInt32(frameCount))
                        }
                    }
                } catch {
                    return noErr
                }
            } else {
                return noErr
            }
        }
        
        guard entry.audioStreamState.processedDataFormat else {
            return noErr
        }
        
        // Handle seek requests
        if let playingEntry = playerContext.audioPlayingEntry,
           playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0 {
            // This is the correct usage of .processSource - only for seek requests
            processorCallback?(.processSource)
            if rendererContext.waiting.value {
                rendererContext.packetsSemaphore.signal()
            }
            return noErr
        }
        
        // Decode frames continuously - matching AudioFileStreamProcessor behavior
        // Wait for renderer buffer space if needed, just like regular audio processing
        var consecutiveNoFrames = 0
        var totalDecoded = 0
        
        decodeLoop: while true {
            // Check player state
            if playerContext.internalState == .disposed
                || playerContext.internalState == .pendingNext
                || playerContext.internalState == .stopped {
                break
            }
            
            // Check if there's space in the buffer
            rendererContext.lock.lock()
            let totalFrames = rendererContext.bufferContext.totalFrameCount
            let usedFrames = rendererContext.bufferContext.frameUsedCount
            rendererContext.lock.unlock()
            
            guard usedFrames <= totalFrames else {
                break decodeLoop
            }
            
            var framesLeft = totalFrames - usedFrames
            
            if framesLeft == 0 {
                while true {
                    rendererContext.lock.lock()
                    let totalFrames = rendererContext.bufferContext.totalFrameCount
                    let usedFrames = rendererContext.bufferContext.frameUsedCount
                    rendererContext.lock.unlock()
                    
                    if usedFrames > totalFrames {
                        break decodeLoop
                    }
                    
                    framesLeft = totalFrames - usedFrames
                    
                    if framesLeft > 0 {
                        break
                    }
                    
                    if playerContext.internalState == .disposed
                        || playerContext.internalState == .pendingNext
                        || playerContext.internalState == .stopped {
                        break decodeLoop
                    }
                    
                    if let playingEntry = playerContext.audioPlayingEntry,
                       playingEntry.seekRequest.requested, playingEntry.calculatedBitrate() > 0 {
                        processorCallback?(.processSource)
                        if rendererContext.waiting.value {
                            rendererContext.packetsSemaphore.signal()
                        }
                        break decodeLoop
                    }
                    
                    rendererContext.waiting.write { $0 = true }
                    rendererContext.packetsSemaphore.wait()
                    rendererContext.waiting.write { $0 = false }
                }
            }
            
            let availableBytes = vfDecoder.availableBytes()
            if availableBytes < 4096 {
                consecutiveNoFrames += 1
                if consecutiveNoFrames >= 3 {
                    break decodeLoop
                }
                continue
            }
            
            let status = decodeAndFillBuffer()
            if status != noErr {
                consecutiveNoFrames += 1
                if consecutiveNoFrames >= 3 {
                    break decodeLoop
                }
            } else {
                consecutiveNoFrames = 0
                totalDecoded += 1
            }
        }
        
        if totalDecoded > 0 && rendererContext.waiting.value {
            rendererContext.packetsSemaphore.signal()
        }
        
        return noErr
    }
    
    /// Decode audio and fill the renderer buffer
    /// - Returns: noErr if frames were decoded, otherwise an error/no-data status
    private func decodeAndFillBuffer() -> OSStatus {
        guard let pcmBuffer = pcmBuffer else { 
            return OSStatus(-1)
        }
        
        let framesRead = vfDecoder.readFrames(into: pcmBuffer, frameCount: frameCount)
        
        if framesRead <= 0 {
            return OSStatus(-1)
        }
        
        pcmBuffer.frameLength = UInt32(framesRead)
        processDecodedAudio(pcmBuffer: pcmBuffer, framesRead: framesRead)
        totalFramesProcessed += framesRead
        
        return noErr
    }
    
    // MARK: - Audio Format Setup
    
    // Setup audio format using the processingFormat from VorbisFileDecoder
    private func setupAudioFormat() {
        guard let entry = playerContext.audioReadingEntry, 
              let processingFormat = vfDecoder.processingFormat else { return }
        
        entry.lock.lock()
        
        // Create an interleaved format matching decoded Vorbis output
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = processingFormat.sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mChannelsPerFrame = UInt32(vfDecoder.channels)
        asbd.mFramesPerPacket = 1
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = asbd.mChannelsPerFrame * 4 // 4 bytes per float
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        
        // Store the format in the entry
        entry.audioStreamFormat = asbd
        entry.sampleRate = Float(vfDecoder.sampleRate)
        entry.packetDuration = Double(1) / Double(vfDecoder.sampleRate)
        
        // For streaming Ogg files, totalPcmSamples may not be available (returns error code)
        // In that case, use bitrate-based duration calculation with container overhead correction
        if vfDecoder.totalPcmSamples > 0 {
            // We have total samples - use packet offset for accurate duration
            entry.audioStreamState.dataPacketOffset = UInt64(vfDecoder.totalPcmSamples)
        } else {
            // Streaming - use bitrate for duration estimation
            if vfDecoder.nominalBitrate > 0 {
                entry.audioStreamState.bitRate = Double(vfDecoder.nominalBitrate) * oggContainerOverheadFactor
            } else {
                // Fallback: use typical bitrates for Vorbis quality
                let estimatedBitrate = vfDecoder.channels == 2 ? fallbackBitrateStereo : fallbackBitrateMono
                entry.audioStreamState.bitRate = estimatedBitrate * oggContainerOverheadFactor
            }
        }
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.lock.unlock()
        
        // Create audio converter from source format to output format
        createAudioConverter(from: asbd, to: outputAudioFormat)
    }
    
    /// Create audio converter from source format to output format
    private func createAudioConverter(from sourceFormat: AudioStreamBasicDescription, to destFormat: AudioStreamBasicDescription) {
        if let existingConverter = audioConverter {
            AudioConverterDispose(existingConverter)
            audioConverter = nil
        }
        
        var source = sourceFormat
        var dest = destFormat
        inputFormat = sourceFormat
        
        let status = AudioConverterNew(&source, &dest, &audioConverter)
        if status != noErr {
            Logger.error("Failed to create AudioConverter", category: .audioRendering)
        }
    }
    
    // MARK: - Audio Processing
    
    /// Process decoded audio using AudioConverter
    /// - Parameters:
    ///   - pcmBuffer: The PCM buffer containing decoded audio
    ///   - framesRead: Number of frames read
    private func processDecodedAudio(pcmBuffer: AVAudioPCMBuffer, framesRead: Int) {
        guard let entry = playerContext.audioReadingEntry,
              let floatChannelData = pcmBuffer.floatChannelData,
              let converter = audioConverter else { return }
        
        let channels = Int(pcmBuffer.format.channelCount)
        let frames = framesRead
        
        // Interleave the deinterleaved PCM data into a contiguous buffer
        let interleavedBufferSize = frames * channels * MemoryLayout<Float>.size
        let interleavedBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: interleavedBufferSize, 
            alignment: MemoryLayout<Float>.alignment
        )
        defer { interleavedBuffer.deallocate() }
        
        let floatBuffer = interleavedBuffer.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            for ch in 0..<channels {
                floatBuffer[frame * channels + ch] = floatChannelData[ch][frame]
            }
        }
        
        // Setup convert info for callback
        var convertInfo = OggVorbisConvertInfo(
            done: false,
            numberOfFrames: UInt32(frames),
            audioBuffer: AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(interleavedBufferSize),
                mData: interleavedBuffer
            )
        )
        
        // Process through AudioConverter
        rendererContext.lock.lock()
        let bufferContext = rendererContext.bufferContext
        let used = bufferContext.frameUsedCount
        let totalFrames = bufferContext.totalFrameCount
        let end = (bufferContext.frameStartIndex + bufferContext.frameUsedCount) % bufferContext.totalFrameCount
        rendererContext.lock.unlock()
        
        guard used <= totalFrames else {
            return
        }
        
        var framesLeft = totalFrames - used
        
        // Wait for buffer space if needed
        if framesLeft == 0 {
            while true {
                rendererContext.lock.lock()
                let currentUsed = rendererContext.bufferContext.frameUsedCount
                let currentTotal = rendererContext.bufferContext.totalFrameCount
                rendererContext.lock.unlock()
                
                if currentUsed > currentTotal {
                    return
                }
                
                framesLeft = currentTotal - currentUsed
                if framesLeft > 0 {
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
                
                rendererContext.waiting.write { $0 = true }
                rendererContext.packetsSemaphore.wait()
                rendererContext.waiting.write { $0 = false }
            }
        }
        
        // Convert using AudioConverterFillComplexBuffer to a temporary buffer
        // Then copy to ring buffer handling wrap-around
        let outputBufferSize = frames * Int(rendererContext.bufferContext.sizeInBytes)
        let outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: outputBufferSize, alignment: MemoryLayout<Float>.alignment)
        defer { outputBuffer.deallocate() }
        
        var framesToDecode = UInt32(frames)
        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 1
        outputBufferList.mBuffers.mNumberChannels = rendererContext.audioBuffer.mNumberChannels
        outputBufferList.mBuffers.mDataByteSize = UInt32(outputBufferSize)
        outputBufferList.mBuffers.mData = outputBuffer
        
        let status = AudioConverterFillComplexBuffer(
            converter,
            _oggVorbisConverterCallback,
            &convertInfo,
            &framesToDecode,
            &outputBufferList,
            nil
        )
        
        guard status == noErr || status == AudioConvertStatus.processed.rawValue else {
            return
        }
        
        // Now copy the converted data to the ring buffer, handling wrap-around
        if framesToDecode == 0 { return }
        
        rendererContext.lock.lock()
        let start = rendererContext.bufferContext.frameStartIndex
        let currentEnd = (rendererContext.bufferContext.frameStartIndex + rendererContext.bufferContext.frameUsedCount) % rendererContext.bufferContext.totalFrameCount
        let totalFrameCount = rendererContext.bufferContext.totalFrameCount
        let currentUsed = rendererContext.bufferContext.frameUsedCount
        rendererContext.lock.unlock()
        
        // Calculate actual space available
        let actualFramesLeft = totalFrameCount - currentUsed
        let framesToCopy = min(framesToDecode, actualFramesLeft)
        
        let bytesPerFrame = Int(rendererContext.bufferContext.sizeInBytes)
        let sourceData = outputBuffer.assumingMemoryBound(to: UInt8.self)
        let destData = rendererContext.audioBuffer.mData?.assumingMemoryBound(to: UInt8.self)
        
        if currentEnd >= start {
            // Ring buffer wraps
            let framesToEnd = totalFrameCount - currentEnd
            let firstChunkFrames = min(framesToCopy, framesToEnd)
            let firstChunkBytes = Int(firstChunkFrames) * bytesPerFrame
            let firstChunkOffset = Int(currentEnd) * bytesPerFrame
            
            // Copy first chunk to end of buffer
            memcpy(destData?.advanced(by: firstChunkOffset), sourceData, firstChunkBytes)
            
            // Copy second chunk to start of buffer if needed
            if firstChunkFrames < framesToCopy {
                let secondChunkFrames = framesToCopy - firstChunkFrames
                let secondChunkBytes = Int(secondChunkFrames) * bytesPerFrame
                memcpy(destData, sourceData.advanced(by: firstChunkBytes), secondChunkBytes)
            }
        } else {
            // No wrap
            let chunkBytes = Int(framesToCopy) * bytesPerFrame
            let offset = Int(currentEnd) * bytesPerFrame
            memcpy(destData?.advanced(by: offset), sourceData, chunkBytes)
        }
        
        fillUsedFrames(framesCount: framesToCopy)
        updateProcessedPackets(inNumberPackets: framesToCopy)
    }
    
    /// Process a seek request
    ///
    /// Seeking is not supported for Ogg Vorbis streams.
    /// For HTTP streams, seeking is extremely difficult because:
    /// 1. Need to find Ogg page boundaries
    /// 2. Need Vorbis headers to initialize decoder
    /// 3. Headers are only at the beginning of the file
    ///
    /// Note: Future enhancement could support seeking in local files
    /// by fetching headers and using libvorbisfile's built-in seeking.
    func processSeek() {
        // Seeking not supported - UI should check AudioPlayer.isSeekable
    }
    
    // MARK: - Helper Methods
    
    /// Update the processed packets information
    /// - Parameter inNumberPackets: The number of packets processed
    private func updateProcessedPackets(inNumberPackets: UInt32) {
        guard let readingEntry = playerContext.audioReadingEntry else { return }
        let processedPackCount = readingEntry.processedPacketsState.count
        let maxPackets = 4096
        
        if processedPackCount < maxPackets {
            let count = min(Int(inNumberPackets), maxPackets - Int(processedPackCount))
            let packetSize: UInt32 = UInt32(readingEntry.audioStreamFormat.mBytesPerFrame)
            
            readingEntry.lock.lock()
            readingEntry.processedPacketsState.sizeTotal += (packetSize * UInt32(count))
            readingEntry.processedPacketsState.count += UInt32(count)
            readingEntry.lock.unlock()
        }
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
    
    /// Clean up allocated buffers
    private func cleanupBuffers() {
        pcmBuffer = nil
    }
}

// MARK: - AudioConverterFillComplexBuffer callback

private func _oggVorbisConverterCallback(
    inAudioConverter _: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let convertInfo = inUserData?.assumingMemoryBound(to: OggVorbisConvertInfo.self) else {
        return -1
    }
    
    // Tell the converter to stop if we're done
    if convertInfo.pointee.done {
        ioNumberDataPackets.pointee = 0
        return AudioConvertStatus.done.rawValue
    }
    
    // Provide input buffer to converter
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers = convertInfo.pointee.audioBuffer
    
    // Set packet count
    ioNumberDataPackets.pointee = convertInfo.pointee.numberOfFrames
    convertInfo.pointee.done = true
    
    return AudioConvertStatus.processed.rawValue
}

