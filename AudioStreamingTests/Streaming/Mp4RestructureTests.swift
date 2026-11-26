import XCTest
@testable import AudioStreaming

final class Mp4RestructureTests: XCTestCase {
    private func atom(_ type: String, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init))
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    private func uint32(_ value: UInt32) -> Data {
        Data(withUnsafeBytes(of: value.bigEndian, Array.init))
    }

    private var ftyp: Data { atom("ftyp", payload: Data("M4A \0\0\u{2}\0M4A isom".utf8)) }

    private func moov(chunkOffsets: [UInt32]) -> Data {
        var stco = Data([0, 0, 0, 0]) + uint32(UInt32(chunkOffsets.count))
        chunkOffsets.forEach { stco.append(uint32($0)) }
        return atom("moov", payload: atom("trak", payload: atom("stco", payload: stco)))
    }

    func testNonOptimizedIsDetectedFromMdatHeaderAlone() throws {
        let mdatSize = 128_486_896
        var head = ftyp + atom("free", payload: Data())
        let mdatOffset = head.count
        head.append(uint32(UInt32(mdatSize)))
        head.append("mdat".data(using: .ascii)!)
        head.append(Data(repeating: 0, count: 4096))

        let result = try Mp4Restructure().checkIsOptimized(data: head)

        XCTAssertEqual(result, .needsRestructure(moovOffset: mdatOffset + mdatSize))
    }

    func testOptimizedIsDetectedFromMoovHeaderAlone() throws {
        var head = ftyp
        head.append(uint32(900_000))
        head.append("moov".data(using: .ascii)!)

        XCTAssertEqual(try Mp4Restructure().checkIsOptimized(data: head), .optimized)
    }

    func testRestructureAfterHeaderOnlyDetectionMovesMoovBeforeMdat() throws {
        let ftyp = self.ftyp
        let mdat = atom("mdat", payload: Data(repeating: 0xAB, count: 64))
        let chunkOffset = UInt32(ftyp.count + 8)
        let moov = moov(chunkOffsets: [chunkOffset])
        let restructure = Mp4Restructure()

        let check = try restructure.checkIsOptimized(data: ftyp + mdat.prefix(16))
        XCTAssertEqual(check, .needsRestructure(moovOffset: ftyp.count + mdat.count))

        let (initialData, mdatOffset) = try restructure.restructureMoov(data: moov)

        XCTAssertEqual(mdatOffset, ftyp.count)
        XCTAssertEqual(initialData, ftyp + self.moov(chunkOffsets: [chunkOffset + UInt32(moov.count)]))
        XCTAssertEqual(restructure.seekAdjusted(offset: 1000), 1000 - moov.count)
    }
}
