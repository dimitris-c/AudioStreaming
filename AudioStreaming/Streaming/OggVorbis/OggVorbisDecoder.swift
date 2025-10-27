//
//  OggVorbisDecoder.swift
//  AudioStreaming
//
//  Created on 25/10/2025.
//

import Foundation
import AudioToolbox
import ogg
import vorbis

/// Swift wrapper for the OggVorbis C decoder
final class OggVorbisDecoder {
    private var decoderContext: OpaquePointer?
    private var isInitialized = false
    
    /// Stream information
    private(set) var streamInfo = OggVorbisStreamInfo()
    
    /// Error type for OggVorbis operations
    enum OggVorbisDecoderError: Error {
        case outOfMemory
        case invalidSetup
        case invalidStream
        case invalidHeader
        case invalidPacket
        case internalError
        case endOfFile
        case unknownError(Int)
        
        init(code: Int32) {
            switch code {
            case OGGVORBIS_ERROR_OUT_OF_MEMORY:
                self = .outOfMemory
            case OGGVORBIS_ERROR_INVALID_SETUP:
                self = .invalidSetup
            case OGGVORBIS_ERROR_INVALID_STREAM:
                self = .invalidStream
            case OGGVORBIS_ERROR_INVALID_HEADER:
                self = .invalidHeader
            case OGGVORBIS_ERROR_INVALID_PACKET:
                self = .invalidPacket
            case OGGVORBIS_ERROR_INTERNAL:
                self = .internalError
            case OGGVORBIS_ERROR_EOF:
                self = .endOfFile
            default:
                self = .unknownError(Int(code))
            }
        }
    }
    
    /// Initialize a new OggVorbis decoder
    init() {
        decoderContext = OggVorbisDecoderCreate()
    }
    
    deinit {
        if let context = decoderContext {
            OggVorbisDecoderDestroy(context)
        }
    }
    
    /// Initialize the decoder with initial data
    /// - Parameter data: The initial Ogg Vorbis data
    /// - Throws: OggVorbisDecoderError if initialization fails
    func initialize(with data: Data) throws {
        guard let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        let result = data.withUnsafeBytes { buffer -> Int32 in
            let baseAddress = buffer.baseAddress!
            return OggVorbisDecoderInit(context, baseAddress, buffer.count)
        }
        
        if result != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: result)
        }
        
        isInitialized = true
        try updateStreamInfo()
    }
    
    /// Process a chunk of Ogg Vorbis data
    /// - Parameter data: The Ogg Vorbis data to process
    /// - Returns: Decoded PCM audio data
    /// - Throws: OggVorbisDecoderError if processing fails
    func processData(_ data: Data) throws -> [Float] {
        guard isInitialized, let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        let result = data.withUnsafeBytes { buffer -> Int32 in
            let baseAddress = buffer.baseAddress!
            return OggVorbisDecoderProcessData(context, baseAddress, buffer.count)
        }
        
        if result != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: result)
        }
        
        // Get the PCM data
        var pcmData: UnsafeMutablePointer<Float>?
        var samplesDecoded: Int32 = 0
        
        let pcmResult = OggVorbisDecoderGetPCMData(context, &pcmData, &samplesDecoded)
        if pcmResult != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: pcmResult)
        }
        
        // Convert to Swift array
        var output = [Float]()
        if let pcm = pcmData, samplesDecoded > 0 {
            let channels = Int(streamInfo.channels)
            let totalSamples = Int(samplesDecoded) * channels
            
            output.reserveCapacity(totalSamples)
            
            // Interleave the channels
            for i in 0..<Int(samplesDecoded) {
                for ch in 0..<channels {
                    let value = pcm[i * channels + ch]
                    output.append(value)
                }
            }
        }
        
        try updateStreamInfo()
        
        return output
    }
    
    /// Seek to a specific time position
    /// - Parameter timeInSeconds: The time to seek to in seconds
    /// - Throws: OggVorbisDecoderError if seeking fails
    func seek(to timeInSeconds: Double) throws {
        guard isInitialized, let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        let result = OggVorbisDecoderSeek(context, timeInSeconds)
        if result != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: result)
        }
        
        try updateStreamInfo()
    }
    
    /// Reset the decoder
    /// - Throws: OggVorbisDecoderError if reset fails
    func reset() throws {
        guard let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        let result = OggVorbisDecoderReset(context)
        if result != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: result)
        }
        
        isInitialized = false
    }
    
    /// Get a comment from the Vorbis stream
    /// - Parameter key: The comment key
    /// - Returns: The comment value, or nil if not found
    func getComment(forKey key: String) -> String? {
        guard isInitialized, let context = decoderContext else {
            return nil
        }
        
        return key.withCString { keyPtr -> String? in
            guard let valuePtr = OggVorbisDecoderGetComment(context, keyPtr) else {
                return nil
            }
            return String(cString: valuePtr)
        }
    }
    
    /// Get all comments from the Vorbis stream
    /// - Returns: A dictionary of all comments
    func getAllComments() -> [String: String] {
        guard isInitialized, let context = decoderContext else {
            return [:]
        }
        
        var comments = [String: String]()
        let count = OggVorbisDecoderGetCommentCount(context)
        
        for i in 0..<count {
            var keyPtr: UnsafePointer<Int8>?
            var valuePtr: UnsafePointer<Int8>?
            
            OggVorbisDecoderGetCommentPair(context, Int32(i), &keyPtr, &valuePtr)
            
            if let keyPtr = keyPtr, let valuePtr = valuePtr {
                let key = String(cString: keyPtr)
                let value = String(cString: valuePtr)
                comments[key] = value
            }
        }
        
        return comments
    }
    
    /// Update the stream info from the decoder
    private func updateStreamInfo() throws {
        guard isInitialized, let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        var info = OggVorbisStreamInfo()
        let result = OggVorbisDecoderGetInfo(context, &info)
        
        if result != OGGVORBIS_SUCCESS {
            throw OggVorbisDecoderError(code: result)
        }
        
        streamInfo.serialNumber = info.serialNumber
        streamInfo.pageCount = info.pageCount
        streamInfo.totalSamples = info.totalSamples
        streamInfo.sampleRate = info.sampleRate
        streamInfo.channels = info.channels
        streamInfo.bitRate = info.bitRate
        streamInfo.nominalBitrate = info.nominalBitrate
        streamInfo.minBitrate = info.minBitrate
        streamInfo.maxBitrate = info.maxBitrate
        streamInfo.blocksize0 = info.blocksize0
        streamInfo.blocksize1 = info.blocksize1
        streamInfo.granulePosition = info.granulePosition
        
        // Update comments
        streamInfo.commentHeader = getAllComments()
    }
    
    /// Convert decoded PCM data to an AudioBuffer
    /// - Parameter pcmData: The decoded PCM data
    /// - Returns: An AudioBuffer containing the PCM data
    func createAudioBuffer(from pcmData: [Float]) -> AudioBuffer {
        var audioBuffer = AudioBuffer()
        audioBuffer.mNumberChannels = UInt32(streamInfo.channels)
        audioBuffer.mDataByteSize = UInt32(pcmData.count * MemoryLayout<Float>.size)
        
        let data = UnsafeMutablePointer<Float>.allocate(capacity: pcmData.count)
        data.initialize(from: pcmData, count: pcmData.count)
        audioBuffer.mData = UnsafeMutableRawPointer(data)
        
        return audioBuffer
    }
}
