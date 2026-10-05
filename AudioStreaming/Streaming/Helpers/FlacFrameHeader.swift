//
//  FlacFrameHeader.swift
//  AudioStreaming
//

import Foundation

/// Reads the position of a FLAC frame from its header (RFC 9639, section 9.1).
///
/// Seeking a FLAC stream lands on a byte offset estimated from the bitrate. FLAC is variable
/// bitrate, so that offset rarely corresponds to the requested time. Every frame header records
/// where the frame starts, which lets the player report the position it actually reached.
enum FlacFrameHeader {
    /// Returns the index of the first sample in the frame starting at `bytes`, or `nil` if `bytes`
    /// does not start with a valid frame header.
    ///
    /// - Parameters:
    ///   - bytes: Data starting at the first byte of a frame.
    ///   - nominalBlockSize: Samples per frame of a fixed-blocksize stream (0 if unknown). Fixed-blocksize
    ///     frames store a frame number instead of a sample number, and only the last frame may be
    ///     shorter than the others, so the larger of this value and the frame's own block size is used.
    static func firstSampleNumber(in bytes: UnsafeRawBufferPointer, nominalBlockSize: UInt32) -> UInt64? {
        // sync code (14 bits) + reserved bit (must be 0) + blocking strategy bit
        guard bytes.count >= 6, bytes[0] == 0xFF, bytes[1] & 0xFE == 0xF8 else { return nil }
        let isVariableBlockSize = bytes[1] & 0x01 == 1

        let blockSizeCode = bytes[2] >> 4
        let sampleRateCode = bytes[2] & 0x0F
        // block size 0 is reserved and sample rate 0b1111 is forbidden; rejecting them helps
        // discard false sync codes found inside audio data
        guard blockSizeCode != 0, sampleRateCode != 0x0F else { return nil }
        // channel assignments 0b1011...0b1111 and the trailing reserved bit are invalid
        guard bytes[3] >> 4 <= 0x0A, bytes[3] & 0x01 == 0 else { return nil }

        var index = 4
        guard let codedNumber = readCodedNumber(bytes, at: &index, maxLength: isVariableBlockSize ? 7 : 6) else {
            return nil
        }

        let blockSize: UInt32
        switch blockSizeCode {
        case 1:
            blockSize = 192
        case 2 ... 5:
            blockSize = 576 << (UInt32(blockSizeCode) - 2)
        case 6:
            guard index < bytes.count else { return nil }
            blockSize = UInt32(bytes[index]) + 1
            index += 1
        case 7:
            guard index + 1 < bytes.count else { return nil }
            blockSize = (UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])) + 1
            index += 2
        default: // 8...15
            blockSize = 256 << (UInt32(blockSizeCode) - 8)
        }

        switch sampleRateCode {
        case 12: index += 1
        case 13, 14: index += 2
        default: break
        }

        guard index < bytes.count, crc8(bytes, count: index) == bytes[index] else { return nil }

        if isVariableBlockSize {
            return codedNumber
        }
        return codedNumber * UInt64(max(blockSize, nominalBlockSize))
    }

    /// Decodes the UTF-8-like coded frame or sample number.
    private static func readCodedNumber(_ bytes: UnsafeRawBufferPointer, at index: inout Int, maxLength: Int) -> UInt64? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        let length: Int
        switch first {
        case 0x00 ... 0x7F: length = 1
        case 0xC0 ... 0xDF: length = 2
        case 0xE0 ... 0xEF: length = 3
        case 0xF0 ... 0xF7: length = 4
        case 0xF8 ... 0xFB: length = 5
        case 0xFC ... 0xFD: length = 6
        case 0xFE: length = 7
        default: return nil
        }
        guard length <= maxLength, index + length <= bytes.count else { return nil }

        var value = length == 1 ? UInt64(first) : UInt64(first & (0x7F >> length))
        for offset in 1 ..< length {
            let byte = bytes[index + offset]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt64(byte & 0x3F)
        }
        index += length
        return value
    }

    /// CRC-8 with polynomial x^8 + x^2 + x + 1, initialised to 0.
    private static func crc8(_ bytes: UnsafeRawBufferPointer, count: Int) -> UInt8 {
        var crc: UInt8 = 0
        for i in 0 ..< count {
            crc ^= bytes[i]
            for _ in 0 ..< 8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }
}
