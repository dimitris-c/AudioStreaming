//
//  OggStreamProcessor.swift
//  AudioStreaming
//
//  Created on 25/10/2025.
//

import Foundation
import AVFoundation
import CoreAudio
import OSLog

/// A processor for Ogg audio streams.
///
/// Ogg is a container, so the renderer plumbing here is codec-agnostic: it
/// drives whatever `OggAudioDecoder` it was handed. `VorbisFileDecoder` wraps
/// libvorbisfile and `OpusFileDecoder` wraps libopusfile.
///
/// Previously named `OggVorbisStreamProcessor`, when Vorbis was the only Ogg
/// codec supported.
final class OggStreamProcessor {
    /// The callback to notify when processing is complete or an error occurs
    var processorCallback: ((FileStreamProcessorEffect) -> Void)?
    
    // MARK: - Constants
    
    /// Correction factor for Ogg container overhead in bitrate-based duration calculation.
    /// Ogg containers add 3-4% overhead (page headers, packet headers, metadata).
    /// The nominal bitrate only accounts for audio data, not container overhead.
    /// By reducing the bitrate slightly, we increase the calculated duration to match reality.
    private let oggContainerOverheadFactor: Double = 0.96  // 4% overhead
    
    // Fallback bitrate estimates now come from the decoder, since sensible
    // values differ per codec (Vorbis 160/96 kbps, Opus 128/64 kbps).
    
    // MARK: - Properties
    
    private let playerContext: AudioPlayerContext
    private let rendererContext: AudioRendererContext
    private let outputAudioFormat: AudioStreamBasicDescription
    
    private let decoder: any OggAudioDecoder
    private var isInitialized = false
    
    // Audio converter for format conversion
    private var audioConverter: AVAudioConverter?
    
    // Buffer for PCM conversion
    private var pcmBuffer: AVAudioPCMBuffer?
    private let frameCount = 1024
    
    // Seeking state (currently unused - seeking not fully supported)
    // Future enhancement: implement proper seeking for local files
    
    // Debug logging
    private var totalFramesProcessed = 0
    private var dataChunkCount = 0
    
    // MARK: - Initialization
    
    /// Initialize the OggStreamProcessor
    /// - Parameters:
    ///   - playerContext: The audio player context
    ///   - rendererContext: The audio renderer context
    ///   - outputAudioFormat: The output audio format
    ///   - decoder: The codec-specific decoder to drive
    init(playerContext: AudioPlayerContext,
         rendererContext: AudioRendererContext,
         outputAudioFormat: AudioStreamBasicDescription,
         decoder: any OggAudioDecoder) {
        self.playerContext = playerContext
        self.rendererContext = rendererContext
        self.outputAudioFormat = outputAudioFormat
        self.decoder = decoder
    }
    
    deinit {
        cleanup()
    }
    
    /// Clean up all resources and reset state
    func cleanup() {
        cleanupBuffers()
        
        audioConverter = nil
        
        // Destroy and reset the decoder
        decoder.destroy()
        isInitialized = false
        totalFramesProcessed = 0
    }
    
    // MARK: - Data Processing
    
    /// Parse Ogg data
    /// - Parameter data: The Ogg data to parse
    /// - Returns: An OSStatus indicating success or failure
    func parseOggData(data: Data) -> OSStatus {
        guard let entry = playerContext.audioReadingEntry else { return 0 }
        
        dataChunkCount += 1
        
        if !isInitialized {
            decoder.create(capacityBytes: 2_097_152)
            isInitialized = true
            totalFramesProcessed = 0
        }
        
        decoder.push(data)
        
        if !entry.audioStreamState.processedDataFormat {
            let availableBytes = decoder.availableBytes()
            
            if availableBytes >= 16384 {
                do {
                    try decoder.openIfNeeded()
                    
                    if decoder.sampleRate > 0 && decoder.channels > 0 {
                        setupAudioFormat()
                        
                        if pcmBuffer == nil, let processingFormat = decoder.processingFormat {
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
            
            let availableBytes = decoder.availableBytes()
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
        
        let framesRead = decoder.readFrames(into: pcmBuffer, frameCount: frameCount)
        
        if framesRead <= 0 {
            return OSStatus(-1)
        }
        
        pcmBuffer.frameLength = UInt32(framesRead)
        processDecodedAudio(pcmBuffer: pcmBuffer, framesRead: framesRead)
        totalFramesProcessed += framesRead
        
        return noErr
    }
    
    // MARK: - Audio Format Setup
    
    // Setup audio format using the processingFormat from the decoder
    private func setupAudioFormat() {
        guard let entry = playerContext.audioReadingEntry, 
              let processingFormat = decoder.processingFormat else { return }
        
        entry.lock.lock()
        
        // Use the decoder's deinterleaved format directly
        var asbd = processingFormat.streamDescription.pointee
        
        // Store the format in the entry
        entry.audioStreamFormat = asbd
        entry.sampleRate = Float(decoder.sampleRate)
        entry.packetDuration = Double(1) / Double(decoder.sampleRate)
        
        // For streaming Ogg files, totalPcmSamples may not be available (returns error code)
        // In that case, use bitrate-based duration calculation with container overhead correction
        if decoder.totalPcmSamples > 0 {
            // We have total samples - use packet offset for accurate duration
            entry.audioStreamState.dataPacketOffset = UInt64(decoder.totalPcmSamples)
        } else {
            // Streaming - use bitrate for duration estimation
            if decoder.nominalBitrate > 0 {
                entry.audioStreamState.bitRate = Double(decoder.nominalBitrate) * oggContainerOverheadFactor
            } else {
                // Fallback: use typical bitrates for this codec
                let estimatedBitrate = decoder.channels == 2 ? decoder.fallbackBitrateStereo : decoder.fallbackBitrateMono
                entry.audioStreamState.bitRate = estimatedBitrate * oggContainerOverheadFactor
            }
        }
        entry.audioStreamState.processedDataFormat = true
        entry.audioStreamState.readyForDecoding = true
        entry.lock.unlock()
        
        // Create audio converter from decoder format to output format
        createAudioConverter(from: processingFormat, to: outputAudioFormat)
    }
    
    /// Create audio converter from decoder format to output format
    private func createAudioConverter(from sourceFormat: AVAudioFormat, to destFormat: AudioStreamBasicDescription) {
        audioConverter = nil
        
        var dest = destFormat
        
        guard let destAVFormat = AVAudioFormat(streamDescription: &dest) else {
            Logger.error("Failed to create output AVAudioFormat", category: .audioRendering)
            return
        }
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: destAVFormat) else {
            Logger.error("Failed to create AVAudioConverter", category: .audioRendering)
            return
        }
        
        audioConverter = converter
    }
    
    // MARK: - Audio Processing
    
    /// Process decoded audio using AVAudioConverter
    /// - Parameters:
    ///   - pcmBuffer: The PCM buffer containing decoded audio
    ///   - framesRead: Number of frames read
    private func processDecodedAudio(pcmBuffer: AVAudioPCMBuffer, framesRead: Int) {
        guard let entry = playerContext.audioReadingEntry,
              let converter = audioConverter else { return }
        
        // Set the input buffer's frame length
        pcmBuffer.frameLength = UInt32(framesRead)
        
        // Create output buffer with converter's output format
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: UInt32(framesRead)
        ) else { return }
        
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
        
        var error: NSError?
        var inputConsumed = false
        
        let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }
        
        guard status != .error, outputBuffer.frameLength > 0 else {
            return
        }
        
        rendererContext.lock.lock()
        let start = rendererContext.bufferContext.frameStartIndex
        let currentEnd = (rendererContext.bufferContext.frameStartIndex + rendererContext.bufferContext.frameUsedCount) % rendererContext.bufferContext.totalFrameCount
        let totalFrameCount = rendererContext.bufferContext.totalFrameCount
        let currentUsed = rendererContext.bufferContext.frameUsedCount
        rendererContext.lock.unlock()
        
        // Calculate actual space available
        let actualFramesLeft = totalFrameCount - currentUsed
        let framesToCopy = min(UInt32(outputBuffer.frameLength), actualFramesLeft)
        
        guard let sourceData = outputBuffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: UInt8.self) else { return }
        let bytesPerFrame = Int(rendererContext.bufferContext.sizeInBytes)
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
    /// Seeking is not supported for Ogg streams.
    /// For HTTP streams, seeking is extremely difficult because:
    /// 1. Need to find Ogg page boundaries
    /// 2. Need codec headers to initialize decoder
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
