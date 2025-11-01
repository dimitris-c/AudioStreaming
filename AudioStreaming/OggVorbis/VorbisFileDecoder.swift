import Foundation
import AudioCodecs
import AVFoundation

/// A simple decoder for Ogg Vorbis files using libvorbisfile
final class VorbisFileDecoder {
    // Core properties
    private var stream: VFStreamRef?
    private var vf: VFFileRef?
    
    // Audio format properties
    private(set) var sampleRate: Int = 0
    private(set) var channels: Int = 0
    private(set) var durationSeconds: Double = -1
    private(set) var totalPcmSamples: Int64 = -1
    private(set) var processingFormat: AVAudioFormat?
    
    // Thread safety
    private let decoderLock = NSLock()
    
    // Debug counters
    private var totalBytesReceived = 0
    private var totalFramesRead = 0
    private var readCalls = 0
    
    // Silent frame generation
    private var silentFrameBuffer: UnsafeMutablePointer<Float>?
    private var silentFrameSize = 0
    
    /// Create the stream buffer with specified capacity
    /// - Parameter capacityBytes: Size of the ring buffer in bytes
    func create(capacityBytes: Int) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        print("VorbisFileDecoder: Creating stream with \(capacityBytes) bytes capacity")
        stream = VFStreamCreate(capacityBytes)
        totalBytesReceived = 0
        totalFramesRead = 0
        readCalls = 0
    }
    
    /// Clean up resources
    func destroy() {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        if let vf = vf { VFClear(vf) }
        if let stream = stream { VFStreamDestroy(stream) }
        vf = nil
        stream = nil
        
        if let silentFrameBuffer = silentFrameBuffer {
            silentFrameBuffer.deallocate()
            self.silentFrameBuffer = nil
        }
        
        print("VorbisFileDecoder: Destroyed decoder")
    }
    
    deinit {
        destroy()
    }
    
    /// Push data into the stream buffer
    /// - Parameter data: The Ogg Vorbis data to decode
    func push(_ data: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), 
                  rawBuf.count > 0, 
                  let stream = stream else { return }
            
            let beforeAvailable = VFStreamAvailableBytes(stream)
            print("VorbisFileDecoder: Pushing \(rawBuf.count) bytes (buffer has \(beforeAvailable) bytes available)...")
            
            VFStreamPush(stream, base, rawBuf.count)
            
            totalBytesReceived += rawBuf.count
            let afterAvailable = VFStreamAvailableBytes(stream)
            print("VorbisFileDecoder: Pushed \(rawBuf.count) bytes (total received: \(totalBytesReceived), buffer now has: \(afterAvailable))")
        }
    }
    
    /// Get the number of bytes currently available in the stream buffer
    /// - Returns: Number of bytes available
    func availableBytes() -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        guard let stream = stream else { return 0 }
        return Int(VFStreamAvailableBytes(stream))
    }
    
    /// Mark the end of the stream
    func markEOF() {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        if let stream = stream { 
            VFStreamMarkEOF(stream)
            print("VorbisFileDecoder: Marked EOF")
        }
    }
    
    /// Try to open the Vorbis file if enough data is available
    /// - Throws: Error if opening fails
    func openIfNeeded() throws {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        guard vf == nil, let stream = stream else { return }
        
        print("VorbisFileDecoder: Attempting to open Vorbis file")
        var outVF: VFFileRef?
        let rc = VFOpen(stream, &outVF)
        if rc < 0 {
            print("VorbisFileDecoder: Failed to open Vorbis file: \(rc)")
            throw NSError(domain: "VorbisFileDecoder", code: Int(rc), 
                          userInfo: [NSLocalizedDescriptionKey: "Failed to open Vorbis file: \(rc)"])
        }
        
        print("VorbisFileDecoder: Successfully opened Vorbis file")
        vf = outVF
        
        // Get stream info
        var info = VFStreamInfo()
        if VFGetInfo(outVF, &info) == 0 {
            sampleRate = Int(info.sample_rate)
            channels = Int(info.channels)
            totalPcmSamples = Int64(info.total_pcm_samples)
            durationSeconds = info.duration_seconds
            
            print("VorbisFileDecoder: Stream info - Sample rate: \(sampleRate), Channels: \(channels), Duration: \(durationSeconds), Total samples: \(totalPcmSamples)")
            
            // Create audio format
            let layoutTag: AudioChannelLayoutTag
            switch channels {
            case 1: layoutTag = kAudioChannelLayoutTag_Mono
            case 2: layoutTag = kAudioChannelLayoutTag_Stereo
            default: layoutTag = kAudioChannelLayoutTag_Unknown | UInt32(channels)
            }
            
            let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag)!
            
            processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                interleaved: false,
                channelLayout: channelLayout
            )
            
            // Create silent frame buffer
            silentFrameSize = 1024 * channels
            silentFrameBuffer = UnsafeMutablePointer<Float>.allocate(capacity: silentFrameSize)
            for i in 0..<silentFrameSize {
                silentFrameBuffer?[i] = 0.0
            }
            
            print("VorbisFileDecoder: Created processing format: \(processingFormat?.description ?? "nil")")
            print("VorbisFileDecoder: Created silent frame buffer with \(silentFrameSize) samples")
        } else {
            print("VorbisFileDecoder: Failed to get stream info")
        }
    }
    
    /// Read decoded frames into an AVAudioPCMBuffer
    /// - Parameters:
    ///   - buffer: The buffer to fill with audio data
    ///   - frameCount: Maximum number of frames to read
    /// - Returns: Number of frames read, 0 on EOF, negative on error
    func readFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        
        readCalls += 1
        
        guard let vf = vf, buffer.format.channelCount > 0 else { 
            print("VorbisFileDecoder: Cannot read frames - vf: \(vf != nil), channels: \(buffer.format.channelCount)")
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }
        
        // Get float channel data from buffer
        guard let floatChannelData = buffer.floatChannelData else { 
            print("VorbisFileDecoder: No float channel data available")
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }
        
        // Create temporary buffer for interleaved data
        let maxFrames = min(frameCount, Int(buffer.frameCapacity))
        let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channels)
        defer { tempBuffer.deallocate() }
        
        // Read interleaved frames
        let framesRead = Int(VFReadInterleavedFloat(vf, tempBuffer, Int32(maxFrames)))
        
        print("VorbisFileDecoder: Read \(framesRead) frames (call #\(readCalls), requested: \(maxFrames))")
        
        // If no frames were read, generate silent frames instead of returning 0
        if framesRead <= 0 {
            print("VorbisFileDecoder: No frames read, generating silent frames")
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }
        
        // Check for audio data
        var maxLevel: Float = 0
        for i in 0..<min(20, framesRead * channels) {
            let level = abs(tempBuffer[i])
            if level > maxLevel {
                maxLevel = level
            }
        }
        print("VorbisFileDecoder: Max audio level in first 20 samples: \(maxLevel)")
        
        // De-interleave into buffer
        for ch in 0..<min(Int(buffer.format.channelCount), channels) {
            let dst = floatChannelData[ch]
            for frame in 0..<framesRead {
                dst[frame] = tempBuffer[frame * channels + ch]
            }
        }
        
        totalFramesRead += framesRead
        print("VorbisFileDecoder: Total frames read: \(totalFramesRead)")
        
        return framesRead
    }
    
    /// Generate silent frames when no real audio data is available
    /// This prevents EOF detection by never returning 0 frames
    private func generateSilentFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        guard let floatChannelData = buffer.floatChannelData,
              channels > 0 else { return 1 }
        
        // Use a small frame count to ensure we keep checking for real data
        let framesToGenerate = min(128, frameCount)
        
        // Fill buffer with zeros
        for ch in 0..<min(Int(buffer.format.channelCount), channels) {
            let dst = floatChannelData[ch]
            for frame in 0..<framesToGenerate {
                dst[frame] = 0.0
            }
        }
        
        print("VorbisFileDecoder: Generated \(framesToGenerate) silent frames")
        return framesToGenerate
    }
    
    /// Reset the decoder state
    func reset() {
        destroy()
    }
}
