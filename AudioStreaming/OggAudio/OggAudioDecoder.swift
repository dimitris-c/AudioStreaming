//
//  OggAudioDecoder.swift
//  AudioStreaming
//

import AVFoundation
import Foundation

/// The decoder interface `OggStreamProcessor` drives.
///
/// Ogg is a container, not a codec: a `kAudioFileOggType` stream can carry
/// Vorbis, Opus, FLAC, or Speex. The renderer plumbing is identical for all of
/// them, so it lives in `OggStreamProcessor` and the codec-specific work sits
/// behind this protocol.
///
/// `VorbisFileDecoder` (libvorbisfile) and `OpusFileDecoder` (libopusfile)
/// both conform.
protocol OggAudioDecoder: AnyObject {
    /// Human-readable codec name, used only for log messages.
    var codecName: String { get }

    /// Output sample rate in Hz. Zero until `openIfNeeded()` succeeds.
    var sampleRate: Int { get }
    /// Output channel count. Zero until `openIfNeeded()` succeeds.
    var channels: Int { get }
    /// Total duration in seconds, or a negative value when unknown (streaming).
    var durationSeconds: Double { get }
    /// Total PCM samples per channel, or -1 when unknown (streaming).
    var totalPcmSamples: Int64 { get }
    /// Nominal or instantaneous bitrate in bits/sec, or 0 when unknown.
    var nominalBitrate: Int { get }
    /// Deinterleaved float32 format matching `sampleRate` / `channels`.
    var processingFormat: AVAudioFormat? { get }

    /// Bitrate estimates used for duration calculation when the container
    /// reports neither a total sample count nor a nominal bitrate.
    var fallbackBitrateStereo: Double { get }
    var fallbackBitrateMono: Double { get }

    /// Allocate the ring buffer.
    func create(capacityBytes: Int)
    /// Release the decoder and ring buffer.
    func destroy()
    /// Feed compressed bytes.
    func push(_ data: Data)
    /// Bytes currently sitting in the ring buffer.
    func availableBytes() -> Int
    /// Signal that no more data is coming.
    func markEOF()
    /// Open the decoder once enough bytes have arrived. Throws while still short.
    func openIfNeeded() throws
    /// Decode into `buffer`. Returns frames written; 0 or negative means no data.
    func readFrames(into buffer: AVAudioPCMBuffer, frameCount: Int) -> Int
    /// Tear down and return to the pre-`create` state.
    func reset()
}

extension OggAudioDecoder {
    // Vorbis-era defaults; OpusFileDecoder overrides with lower values since
    // Opus is typically encoded at 96-128 kbps rather than 160-192.
    var fallbackBitrateStereo: Double { 160_000 }
    var fallbackBitrateMono: Double { 96_000 }
}

// `VorbisFileDecoder` already exposes every member above with matching
// signatures, so conformance is declaration-only.
extension VorbisFileDecoder: OggAudioDecoder {
    var codecName: String { "Vorbis" }
}
