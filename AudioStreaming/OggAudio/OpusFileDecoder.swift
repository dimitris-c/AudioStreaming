//
//  OpusFileDecoder.swift
//  AudioStreaming
//

import AudioCodecs
import AVFoundation
import Foundation
import OSLog

/// A decoder for Ogg Opus streams using libopusfile.
///
/// Structurally a mirror of `VorbisFileDecoder`. Two things differ:
///
/// 1. Opus always decodes to 48 kHz. `OpusHead.input_sample_rate` describes the
///    material that was *encoded*, not the output, and using it as the output
///    rate produces a pitch-shifted stream.
/// 2. libopusfile has no deinterleaved read (no equivalent of `ov_read_float`),
///    so the C bridge deinterleaves into caller-owned buffers. That means this
///    decoder writes straight into the `AVAudioPCMBuffer` channel pointers
///    rather than memcpy'ing from decoder-owned memory.
final class OpusFileDecoder {
    // Core properties
    private var stream: OFStreamRef?
    private var of: OFFileRef?

    // Audio format properties
    private(set) var sampleRate: Int = 0
    private(set) var channels: Int = 0
    private(set) var durationSeconds: Double = -1
    private(set) var totalPcmSamples: Int64 = -1
    private(set) var nominalBitrate: Int = 0
    private(set) var processingFormat: AVAudioFormat?

    // Thread safety
    private let decoderLock = NSLock()

    /// Create the stream buffer with specified capacity
    /// - Parameter capacityBytes: Size of the ring buffer in bytes
    func create(capacityBytes: Int) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        stream = OFStreamCreate(capacityBytes)
    }

    /// Clean up resources
    func destroy() {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if let of = of { OFClear(of) }
        if let stream = stream { OFStreamDestroy(stream) }
        of = nil
        stream = nil
    }

    deinit {
        destroy()
    }

    /// Push data into the stream buffer
    /// - Parameter data: The Ogg Opus data to decode
    func push(_ data: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  rawBuf.count > 0,
                  let stream = stream else { return }

            OFStreamPush(stream, base, rawBuf.count)
        }
    }

    /// Get the number of bytes currently available in the stream buffer
    func availableBytes() -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard let stream = stream else { return 0 }
        return Int(OFStreamAvailableBytes(stream))
    }

    /// Mark the end of the stream
    func markEOF() {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if let stream = stream {
            OFStreamMarkEOF(stream)
        }
    }

    /// Try to open the Opus file if enough data is available
    /// - Throws: Error if opening fails
    func openIfNeeded() throws {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard of == nil, let stream = stream else { return }

        var outOF: OFFileRef?
        let rc = OFOpen(stream, &outOF)
        if rc < 0 {
            // OP_ENOTFORMAT / OP_EBADHEADER on a short read is expected — the
            // caller retries as more bytes arrive.
            Logger.error("Failed to open Opus file (\(rc))", category: .audioRendering)
            throw NSError(domain: "OpusFileDecoder", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to open Opus file"])
        }

        of = outOF

        var info = OFStreamInfo()
        if OFGetInfo(outOF, &info) == 0 {
            sampleRate = Int(info.sample_rate)
            channels = Int(info.channels)
            totalPcmSamples = Int64(info.total_pcm_samples)
            durationSeconds = info.duration_seconds
            nominalBitrate = Int(info.bitrate_nominal)

            let layoutTag: AudioChannelLayoutTag
            switch channels {
            case 1: layoutTag = kAudioChannelLayoutTag_Mono
            case 2: layoutTag = kAudioChannelLayoutTag_Stereo
            default: layoutTag = kAudioChannelLayoutTag_Unknown | UInt32(channels)
            }

            guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else {
                Logger.error("Failed to build channel layout for \(channels) channels",
                             category: .audioRendering)
                return
            }

            processingFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                interleaved: false,
                channelLayout: channelLayout
            )
        } else {
            Logger.error("Failed to get Opus stream info", category: .audioRendering)
        }
    }

    /// Read decoded frames into an AVAudioPCMBuffer
    /// - Returns: Number of frames read; a small run of silent frames when no
    ///   data is available, matching `VorbisFileDecoder` so the renderer never
    ///   sees a zero-frame read as end-of-track.
    func readFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        guard let of = of,
              buffer.format.channelCount > 0,
              let floatChannelData = buffer.floatChannelData else {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        let maxFrames = min(frameCount, Int(buffer.frameCapacity))
        let channelCount = min(Int(buffer.format.channelCount), channels)
        guard channelCount > 0, maxFrames > 0 else {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        // Hand the bridge the buffer's own channel pointers. It deinterleaves
        // directly into them, so there is no second copy.
        var channelPointers = [UnsafeMutablePointer<Float>?]()
        channelPointers.reserveCapacity(channelCount)
        for ch in 0..<channelCount {
            channelPointers.append(floatChannelData[ch])
        }

        let framesRead = channelPointers.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Int(OFReadFloatDeinterleaved(of, base, Int32(maxFrames), Int32(channelCount)))
        }

        if framesRead <= 0 {
            return generateSilentFrames(into: buffer, frameCount: frameCount)
        }

        return framesRead
    }

    /// Generate silent frames when no real audio data is available.
    /// Prevents the renderer from treating a starved buffer as EOF.
    private func generateSilentFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int {
        guard let floatChannelData = buffer.floatChannelData,
              channels > 0 else { return 1 }

        let framesToGenerate = min(128, frameCount)

        for ch in 0..<min(Int(buffer.format.channelCount), channels) {
            let dst = floatChannelData[ch]
            for frame in 0..<framesToGenerate {
                dst[frame] = 0.0
            }
        }

        return framesToGenerate
    }

    /// Reset the decoder state
    func reset() {
        destroy()
    }
}

extension OpusFileDecoder: OggAudioDecoder {
    var codecName: String { "Opus" }

    // Opus is typically encoded well below Vorbis bitrates for equivalent
    // quality, so the streaming duration estimate uses lower fallbacks.
    var fallbackBitrateStereo: Double { 128_000 }
    var fallbackBitrateMono: Double { 64_000 }
}
