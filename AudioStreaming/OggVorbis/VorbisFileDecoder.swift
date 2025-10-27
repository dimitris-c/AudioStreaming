import Foundation
import AudioCodecs
import AVFoundation

final class VorbisFileDecoder {
    private var stream: VFStreamRef?
    private var vf: VFFileRef?
    private(set) var sampleRate: Int = 0
    private(set) var channels: Int = 0
    private(set) var durationSeconds: Double = -1
    private(set) var totalPcmSamples: Int64 = -1
    
    // Following SFBAudioEngine's approach
    private(set) var processingFormat: AVAudioFormat?
    
    func create(capacityBytes: Int) {
        stream = VFStreamCreate(capacityBytes)
    }
    
    func destroy() {
        if let vf = vf { VFClear(vf) }
        if let stream = stream { VFStreamDestroy(stream) }
        vf = nil
        stream = nil
    }
    
    deinit { destroy() }
    
    func push(_ data: Data) {
        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), rawBuf.count > 0, let stream = stream else { return }
            VFStreamPush(stream, base, rawBuf.count)
            print("VorbisFileDecoder: Pushed \(rawBuf.count) bytes to stream buffer")
        }
    }
    
    func markEOF() {
        if let stream = stream { VFStreamMarkEOF(stream) }
    }
    
    func openIfNeeded() throws {
        guard vf == nil, let stream = stream else { return }
        var outVF: VFFileRef?
        let rc = VFOpen(stream, &outVF)
        if rc < 0 {
            throw NSError(domain: "VorbisFileDecoder", code: Int(rc), 
                          userInfo: [NSLocalizedDescriptionKey: "VFOpen failed: \(rc)"])
        }
        vf = outVF
        var info = VFStreamInfo()
        if VFGetInfo(outVF, &info) == 0 {
            sampleRate = Int(info.sample_rate)
            channels = Int(info.channels)
            totalPcmSamples = Int64(info.total_pcm_samples)
            durationSeconds = info.duration_seconds
            
            // Create processing format exactly like SFBAudioEngine
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
                interleaved: false, // Non-interleaved like SFBAudioEngine
                channelLayout: channelLayout
            )
            print("VorbisFileDecoder: Created processing format: \(processingFormat?.description ?? "nil")")
        }
    }
    
    // Read frames into non-interleaved buffer (like SFBAudioEngine)
    func readFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        guard let vf = vf, let format = processingFormat else { return 0 }
        
        // Get float channel data from buffer
        guard let floatChannelData = buffer.floatChannelData else { return 0 }
        
        // Temporary buffer for interleaved data from vorbisfile
        let maxFrames = min(frameCount, Int(buffer.frameCapacity))
        let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channels)
        defer { tempBuffer.deallocate() }
        
        // Read interleaved frames - try to read larger chunks for better performance
        // This helps avoid the "2 seconds of audio" issue by ensuring we get enough data
        let requestedFrames = Int32(maxFrames)
        let framesRead = Int(VFReadInterleavedFloat(vf, tempBuffer, requestedFrames))
        if framesRead <= 0 { return framesRead }
        
        // Apply volume boost to help with quiet files
        let boost: Float = 1.8
        for i in 0..<(framesRead * channels) {
            tempBuffer[i] *= boost
        }
        
        // De-interleave into buffer
        for ch in 0..<min(Int(format.channelCount), channels) {
            let dst = floatChannelData[ch]
            for frame in 0..<framesRead {
                dst[frame] = tempBuffer[frame * channels + ch]
            }
        }
        
        if framesRead > 0 {
            print("VorbisFileDecoder: Read \(framesRead) frames, max level: \(getMaxLevel(buffer: buffer, frameCount: framesRead))")
        }
        
        return framesRead
    }
    
    // For debugging audio levels
    private func getMaxLevel(buffer: AVAudioPCMBuffer, frameCount: Int) -> Float {
        guard let floatData = buffer.floatChannelData, frameCount > 0 else { return 0 }
        var max: Float = 0
        
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<min(20, frameCount) {
                let sample = abs(floatData[ch][i])
                if sample > max { max = sample }
            }
        }
        
        return max
    }
}


