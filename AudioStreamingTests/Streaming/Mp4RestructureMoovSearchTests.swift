import XCTest
@testable import AudioStreaming

/// The data fetched for a non-optimized MP4 starts at the end of `mdat`, which is not always
/// the `moov` atom: tag editors and muxers can leave `free` or `udta` atoms in between.
final class Mp4RestructureMoovSearchTests: XCTestCase {
    private func uint32(_ value: UInt32) -> Data {
        Data(withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    private func atom(_ type: String, payload: Data) -> Data {
        uint32(UInt32(8 + payload.count)) + type.data(using: .ascii)! + payload
    }

    private var ftyp: Data { atom("ftyp", payload: Data("M4A \0\0\u{2}\0M4A isom".utf8)) }

    private func moov(chunkOffsets: [UInt32]) -> Data {
        var stco = Data([0, 0, 0, 0]) + uint32(UInt32(chunkOffsets.count))
        chunkOffsets.forEach { stco.append(uint32($0)) }
        return atom("moov", payload: atom("trak", payload: atom("stco", payload: stco)))
    }

    private func restructure(tailAfterMdat tail: Data, chunkOffset: UInt32) throws -> (Data, Int, Int) {
        let mdat = atom("mdat", payload: Data(repeating: 0xAB, count: 64))
        let restructure = Mp4Restructure()
        let check = try restructure.checkIsOptimized(data: ftyp + mdat)
        XCTAssertEqual(check, .needsRestructure(moovOffset: ftyp.count + mdat.count))
        let (initialData, mdatOffset) = try restructure.restructureMoov(data: tail)
        return (initialData, mdatOffset, restructure.seekAdjusted(offset: 0))
    }

    func testMoovDirectlyAfterMdat() throws {
        let chunkOffset = UInt32(ftyp.count + 8)
        let moov = moov(chunkOffsets: [chunkOffset])

        let (initialData, mdatOffset, adjustedZero) = try restructure(tailAfterMdat: moov, chunkOffset: chunkOffset)

        XCTAssertEqual(mdatOffset, ftyp.count)
        XCTAssertEqual(initialData, ftyp + self.moov(chunkOffsets: [chunkOffset + UInt32(moov.count)]))
        XCTAssertEqual(adjustedZero, -moov.count)
    }

    func testMoovAfterFreeAtom() throws {
        let chunkOffset = UInt32(ftyp.count + 8)
        let moov = moov(chunkOffsets: [chunkOffset])
        let tail = atom("free", payload: Data(count: 20)) + moov

        let (initialData, mdatOffset, adjustedZero) = try restructure(tailAfterMdat: tail, chunkOffset: chunkOffset)

        XCTAssertEqual(mdatOffset, ftyp.count)
        XCTAssertEqual(initialData, ftyp + self.moov(chunkOffsets: [chunkOffset + UInt32(moov.count)]))
        XCTAssertEqual(adjustedZero, -moov.count)
    }

    func testMoovAfterSeveralAtoms() throws {
        let chunkOffset = UInt32(ftyp.count + 8)
        let moov = moov(chunkOffsets: [chunkOffset])
        let tail = atom("free", payload: Data(count: 3)) + atom("udta", payload: Data(repeating: 7, count: 40)) + moov

        let (initialData, _, _) = try restructure(tailAfterMdat: tail, chunkOffset: chunkOffset)

        XCTAssertEqual(initialData, ftyp + self.moov(chunkOffsets: [chunkOffset + UInt32(moov.count)]))
    }

    /// An atom with a 64-bit size (size field 1, as qt-faststart handles) before moov.
    func testMoovAfterAtomWithExtendedSize() throws {
        let chunkOffset = UInt32(ftyp.count + 8)
        let moov = moov(chunkOffsets: [chunkOffset])
        let payload = Data(repeating: 3, count: 24)
        let extendedFree = uint32(1) + "free".data(using: .ascii)!
            + Data(withUnsafeBytes(of: UInt64(16 + payload.count).bigEndian, Array.init)) + payload
        let tail = extendedFree + moov

        let (initialData, _, _) = try restructure(tailAfterMdat: tail, chunkOffset: chunkOffset)

        XCTAssertEqual(initialData, ftyp + self.moov(chunkOffsets: [chunkOffset + UInt32(moov.count)]))
    }

    /// qt-faststart rejects a moov smaller than 16 bytes ("bad moov atom size").
    func testTooSmallMoovThrows() {
        let mdat = atom("mdat", payload: Data(repeating: 0xAB, count: 64))
        let restructure = Mp4Restructure()
        XCTAssertNoThrow(try restructure.checkIsOptimized(data: ftyp + mdat))
        let tail = atom("free", payload: Data(count: 4)) + atom("moov", payload: Data(count: 4))

        XCTAssertThrowsError(try restructure.restructureMoov(data: tail)) { error in
            guard case .invalidMoovAtom = error as? Mp4RestructureError else {
                return XCTFail("expected invalidMoovAtom, got \(error)")
            }
        }
    }

    func testMissingMoovThrows() {
        let mdat = atom("mdat", payload: Data(repeating: 0xAB, count: 64))
        let restructure = Mp4Restructure()
        XCTAssertNoThrow(try restructure.checkIsOptimized(data: ftyp + mdat))
        let tail = atom("free", payload: Data(count: 20)) + atom("udta", payload: Data(count: 12))

        XCTAssertThrowsError(try restructure.restructureMoov(data: tail))
    }

    func testZeroSizedAtomBeforeMoovThrowsInsteadOfLooping() {
        let mdat = atom("mdat", payload: Data(repeating: 0xAB, count: 64))
        let restructure = Mp4Restructure()
        XCTAssertNoThrow(try restructure.checkIsOptimized(data: ftyp + mdat))
        let tail = uint32(0) + "free".data(using: .ascii)! + Data(count: 24)

        XCTAssertThrowsError(try restructure.restructureMoov(data: tail))
    }
}
