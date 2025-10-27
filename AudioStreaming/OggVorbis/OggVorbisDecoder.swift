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
import AudioCodecs

/// Swift wrapper for OggVorbisStreamInfo
struct OggVorbisStreamData {
    // Base properties from C struct
    var serialNumber: UInt32 = 0
    var pageCount: UInt64 = 0
    var totalSamples: UInt64 = 0
    var sampleRate: UInt32 = 0
    var channels: UInt8 = 0
    var bitRate: UInt32 = 0
    var nominalBitrate: UInt32 = 0
    var minBitrate: UInt32 = 0
    var maxBitrate: UInt32 = 0
    var blocksize0: Int32 = 0
    var blocksize1: Int32 = 0
    var granulePosition: Int64 = 0
    
    // Additional Swift properties
    var commentHeader: [String: String] = [:]
    var pageOffsets: [Int64] = []
    var pageGranules: [Int64] = []
    
    /// Initialize from C struct
    init(from cInfo: AudioCodecs.OggVorbisStreamInfo) {
        self.serialNumber = cInfo.serialNumber
        self.pageCount = cInfo.pageCount
        self.totalSamples = cInfo.totalSamples
        self.sampleRate = cInfo.sampleRate
        self.channels = cInfo.channels
        self.bitRate = cInfo.bitRate
        self.nominalBitrate = cInfo.nominalBitrate
        self.minBitrate = cInfo.minBitrate
        self.maxBitrate = cInfo.maxBitrate
        self.blocksize0 = cInfo.blocksize0
        self.blocksize1 = cInfo.blocksize1
        self.granulePosition = cInfo.granulePosition
    }
    
    init() {
        // Default initializer
    }
}

/// Swift wrapper for the OggVorbis C decoder
final class OggVorbisDecoder {
    private var decoderContext: OpaquePointer?
    
    /// Whether the decoder has been successfully initialized
    private(set) var isInitialized = false
    
    /// Stream information
    private(set) var streamInfo = OggVorbisStreamData()
    
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
        
        init(code: OggVorbisError) {
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
                self = .unknownError(Int(code.rawValue))
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
        
        print("OggVorbisDecoder: Initializing with \(data.count) bytes")
        
        // No need to store the data as the C code now accumulates it
        
        let result = data.withUnsafeBytes { buffer -> Int32 in
            let baseAddress = buffer.baseAddress!
            return OggVorbisDecoderInit(context, baseAddress, buffer.count).rawValue
        }
        
        if result != OGGVORBIS_SUCCESS.rawValue {
            // If we need more data, we should store what we have and continue
            if result == OGGVORBIS_ERROR_INVALID_HEADER.rawValue {
                print("OggVorbisDecoder: Need more data for initialization")
                // We'll handle this in the processData method
                return
            }
            throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result))
        }
        
        isInitialized = true
        try updateStreamInfo()
        
        // Print stream info for debugging
        print("OggVorbisDecoder: Successfully initialized - Sample rate: \(streamInfo.sampleRate), Channels: \(streamInfo.channels), Bitrate: \(streamInfo.bitRate)")
    }
    
    /// Process a chunk of Ogg Vorbis data
    /// - Parameter data: The Ogg Vorbis data to process
    /// - Returns: Decoded PCM audio data
    /// - Throws: OggVorbisDecoderError if processing fails
    func processData(_ data: Data) throws -> [Float] {
        guard let context = decoderContext else {
            throw OggVorbisDecoderError.invalidSetup
        }
        
        // If not initialized yet, try to initialize with this data
        if !isInitialized {
            print("OggVorbisDecoder: Not initialized yet, trying to initialize with \(data.count) more bytes")
            
            let result = data.withUnsafeBytes { buffer -> Int32 in
                let baseAddress = buffer.baseAddress!
                return OggVorbisDecoderInit(context, baseAddress, buffer.count).rawValue
            }
            
            if result != OGGVORBIS_SUCCESS.rawValue {
                // Still need more data
                if result == OGGVORBIS_ERROR_INVALID_HEADER.rawValue {
                    print("OggVorbisDecoder: Still need more data for initialization")
                    return []
                }
                throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result))
            }
            
            isInitialized = true
            try updateStreamInfo()
            print("OggVorbisDecoder: Successfully initialized with additional data")
            print("OggVorbisDecoder: Stream info - Sample rate: \(streamInfo.sampleRate), Channels: \(streamInfo.channels), Bitrate: \(streamInfo.bitRate)")
            return [] // Return empty for this round
        }
        
        // Normal processing for initialized decoder
        let result = data.withUnsafeBytes { buffer -> Int32 in
            let baseAddress = buffer.baseAddress!
            return OggVorbisDecoderProcessData(context, baseAddress, buffer.count).rawValue
        }
        
        if result != OGGVORBIS_SUCCESS.rawValue {
            // If we get an invalid packet error, we can continue - it just means this packet couldn't be decoded
            if result == OGGVORBIS_ERROR_INVALID_PACKET.rawValue {
                print("OggVorbisDecoder: Warning - skipping invalid packet")
            } else {
                throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result))
            }
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
            
            print("OggVorbisDecoder: Decoded \(samplesDecoded) PCM samples, \(channels) channels, total samples: \(totalSamples)")
            output.reserveCapacity(totalSamples)
            
            // In our C implementation, we've already interleaved the channels
            // So we can just copy the data directly
            for i in 0..<totalSamples {
                output.append(pcm[i])
            }
            
            // Free the memory allocated in C
            pcm.deallocate()
            
            // Debug: Print first few samples to verify data
            if output.count > 10 {
                let samples = Array(output.prefix(10))
                print("OggVorbisDecoder: First 10 samples: \(samples)")
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
        if result.rawValue != OGGVORBIS_SUCCESS.rawValue {
            throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result.rawValue))
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
        if result.rawValue != OGGVORBIS_SUCCESS.rawValue {
            throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result.rawValue))
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
        
        var info = AudioCodecs.OggVorbisStreamInfo()
        let result = OggVorbisDecoderGetInfo(context, &info)
        
        if result.rawValue != OGGVORBIS_SUCCESS.rawValue {
            throw OggVorbisDecoderError(code: OggVorbisError(rawValue: result.rawValue))
        }
        
        // Create a new Swift struct from the C struct
        var newStreamInfo = OggVorbisStreamData(from: info)
        
        // Copy over any existing Swift-specific data we want to preserve
        newStreamInfo.pageOffsets = streamInfo.pageOffsets
        newStreamInfo.pageGranules = streamInfo.pageGranules
        
        // Add comments
        newStreamInfo.commentHeader = getAllComments()
        
        // Update our stream info
        streamInfo = newStreamInfo
    }
    
    /// Convert decoded PCM data to an AudioBuffer
    /// - Parameter pcmData: The decoded PCM data
    /// - Returns: An AudioBuffer containing the PCM data
    func createAudioBuffer(from pcmData: [Float]) -> AudioBuffer {
        var audioBuffer = AudioBuffer()
        let channels = Int(streamInfo.channels)
        let samplesPerChannel = pcmData.count / channels
        
        // Set up the audio buffer properties for interleaved PCM data
        audioBuffer.mNumberChannels = UInt32(channels)
        audioBuffer.mDataByteSize = UInt32(pcmData.count * MemoryLayout<Float>.size)
        
        // Create a buffer for the PCM data
        let data = UnsafeMutablePointer<Float>.allocate(capacity: pcmData.count)
        
        // Copy the PCM data directly - it's already interleaved by our C code
        data.initialize(from: pcmData, count: pcmData.count)
        
        audioBuffer.mData = UnsafeMutableRawPointer(data)
        
        print("OggVorbisDecoder: Created interleaved audio buffer with \(pcmData.count) samples, \(channels) channels, \(samplesPerChannel) samples per channel")
        
//        // Debug: Print a few values to verify data
//        if pcmData.count >= 10 {
//            let samples = Array(pcmData.prefix(10))
//            print("OggVorbisDecoder: PCM sample values: \(samples)")
//            
//            // Print the magnitude of the samples to check for very quiet audio
//            let magnitudes = samples.map { abs($0) }
//            let maxMagnitude = magnitudes.max() ?? 0
//            let avgMagnitude = magnitudes.reduce(0, +) / Float(magnitudes.count)
//            print("OggVorbisDecoder: Sample magnitudes - Max: \(maxMagnitude), Avg: \(avgMagnitude)")
//        }
        
        return audioBuffer
    }
}
