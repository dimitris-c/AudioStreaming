//
//  OggCodecSniffer.swift
//  AudioStreaming
//

import Foundation

/// Identifies which codec an Ogg bitstream carries.
///
/// This exists because the transport layer cannot tell us. Ogg is a container,
/// and the registered MIME type `audio/ogg` is shared by Vorbis, Opus, Speex,
/// and FLAC-in-Ogg. Navidrome, for instance, serves an Opus transcode as
/// `audio/ogg` (`resources/mime_types.yaml`), so a Content-Type check alone
/// routes Opus into the Vorbis decoder, which rejects it.
///
/// The only reliable discriminator is the first packet of the first page.
enum OggCodec: Equatable {
    case vorbis
    case opus
    /// Recognised as Ogg, but the codec is not one we decode.
    case unsupported
}

enum OggCodecSniffer {
    /// Bytes needed in the worst realistic case: 27-byte page header plus a
    /// 255-entry segment table plus the 8-byte codec magic.
    static let maxHeaderLength = 27 + 255 + 8

    /// Bytes needed for a typical first page (single segment).
    static let typicalHeaderLength = 36

    /// Identifies the codec from the start of an Ogg bitstream.
    ///
    /// - Returns: the codec, or `nil` when `bytes` is not yet long enough to
    ///   decide. `nil` means "feed me more", `.unsupported` means "give up".
    static func sniff(_ bytes: [UInt8]) -> OggCodec? {
        // Ogg page header layout (RFC 3533 §6):
        //   0..3   capture pattern "OggS"
        //   4      stream structure version
        //   5      header type flag
        //   6..13  granule position
        //   14..17 bitstream serial number
        //   18..21 page sequence number
        //   22..25 CRC checksum
        //   26     number of page segments
        //   27..   segment table (one byte per segment)
        //   then   packet data
        guard bytes.count >= 27 else { return nil }

        func matches(_ ascii: String, at offset: Int) -> Bool {
            let pattern = Array(ascii.utf8)
            guard bytes.count >= offset + pattern.count else { return false }
            return Array(bytes[offset..<offset + pattern.count]) == pattern
        }

        guard matches("OggS", at: 0) else { return .unsupported }

        let segmentCount = Int(bytes[26])
        let payloadOffset = 27 + segmentCount

        // "OpusHead" is 8 bytes; the Vorbis identification header is a 0x01
        // packet-type byte followed by "vorbis". Need the longer of the two
        // before we can rule either out.
        guard bytes.count >= payloadOffset + 8 else { return nil }

        if matches("OpusHead", at: payloadOffset) {
            return .opus
        }
        if bytes[payloadOffset] == 0x01, matches("vorbis", at: payloadOffset + 1) {
            return .vorbis
        }

        // Ogg FLAC ("\x7FFLAC"), Speex ("Speex   "), Theora, etc.
        return .unsupported
    }

    /// Convenience overload for the streaming path.
    static func sniff(_ data: Data) -> OggCodec? {
        sniff([UInt8](data.prefix(maxHeaderLength)))
    }
}
