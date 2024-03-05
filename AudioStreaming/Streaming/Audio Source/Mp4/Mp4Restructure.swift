// Copyright © Blockchain Luxembourg S.A. All rights reserved.

import Foundation

struct MP4Atom: Equatable, CustomDebugStringConvertible {
    let type: Int
    let size: Int
    let offset: Int
    var data: Data?
    
    var debugDescription: String {
        "[Atom][size: \(size))][type: \(Atoms.integerToFourCC(type) ?? "")][offset: \(offset)]"
    }
}

/// These are some atoms, helpful for audio mp4
enum Atoms {
    static var ftyp: Int { fourCcToInt("ftyp") }
    static var moov: Int { fourCcToInt("moov") }
    static var mdat: Int { fourCcToInt("mdat") }
    static var free: Int { fourCcToInt("free") }
    
    static var cmov: Int { fourCcToInt("cmov") }
    static var stco: Int { fourCcToInt("stco") }
    static var co64: Int { fourCcToInt("c064") }
    
    static var atomPreampleSize: Int = 8
    
    static func fourCcToInt(_ fourCc: String) -> Int {
        let data = fourCc.data(using: .ascii)!
        return Int(bigEndian: Int(data: data))
    }
    
    static func integerToFourCC(_ value: Int) -> String? {
        guard value >= 0 && value <= 0xFFFFFFFF else {
            return nil // Integer value out of range
        }
        
        var bytes: [UInt8] = []
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
        
        let data = Data(bytes)
        return String(data: data, encoding: .ascii)
    }
}

enum Mp4RestructureError: Error {
    case unableToRestructureData
    case missingMoovData
    case invalidMoovAtom
    case invalidAtomSize
    case invalidAtomType
    case invalidOffset
    case compressedAtomNotSupported
    case networkError(Error)
}


final class Mp4Restructure {
    
    struct RestructuredData {
        var initialData: Data
        var mdatOffset: Int
    }
    
    private var audioData: Data = Data()
    
    var offset: Int = 0
    
    var atoms: [MP4Atom] = []
    var ftyp: MP4Atom?
    
    var foundMoov = false
    var foundMdat = false
    
    var task: NetworkDataStream?
    
    private(set) var dataOptimized: Bool = false
    
    private let url: URL
    private let networking: NetworkingClient
    
    init(url: URL, networking: NetworkingClient) {
        self.url = url
        self.networking = networking
    }

    func clear() {
        offset = 0
        audioData = Data()
    }
    
    deinit {
        audioData = Data()
    }

    ///
    /// Gather audio and parse along the way, if moov atom is found, continue as usual
    /// if mdat is found before moov:
    ///  - Get mdat size and make a byte request Range: bytes=(mdatAtomSize + offset)-
    ///  - once the request is complete search and restructure moov atom
    ///  - make a byte request Range: bytes=(moovAtomSize + offset)-mdatAtomSize
    /// Atoms needs to be as following for the AudioFileStreamParse to work
    /// [ftyp][moov][mdat]
    ///
    
    func optimizeIfNeeded(completion: @escaping (Result<RestructuredData?, Error>) -> Void) {
        task = networking.stream(request: urlForPartialContent(with: url, offset: 0))
            .responseStream { [weak self] event in
                guard let self else { return }
                switch event {
                case .response:
                    break
                case let .stream(.success(response)):
                    guard let data = response.data else {
                        audioData = Data()
                        completion(.failure(Mp4RestructureError.unableToRestructureData))
                        return
                    }
                    audioData.append(data)
                    let value = self.checkIsOptimized(data: audioData)
                    if let offset = value.offset, !value.optimized {
                        // stop request, fetch moov and restructure
                        audioData = Data()
                        task?.cancel()
                        task = nil
                        self.fetchAndRestructureMoovAtom(offset: offset) { result in
                            switch result {
                            case .success(let value):
                                let data = value.0
                                let offset = value.1
                                self.dataOptimized = true
                                completion(.success(RestructuredData(initialData: data, mdatOffset: offset)))
                            case .failure(_):
                                break
                            }
                        }
                    } else {
                        audioData = Data()
                        task?.cancel()
                        task = nil
                        completion(.success(nil))
                    }
                    break
                case let .stream(.failure(error)):
                    completion(.failure(Mp4RestructureError.networkError(error)))
                case .complete:
                    break
                }
            }
        task?.resume()
    }
    
    func fetchAndRestructureMoovAtom(offset: Int, completion: @escaping (Result<(Data, Int), Error>) -> Void) {
        networking.task(request: urlForPartialContent(with: url, offset: offset)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let data = try self.restructureMoov(data: data)
                    let mdatIndex = self.atoms.firstIndex(where: { $0.type == Atoms.mdat })
                    let atoms = self.atoms.filter { $0.type != Atoms.mdat || $0.type == Atoms.moov }
                    let dataOfAtomsBefore = self.atoms.filter { $0.data != nil }.compactMap(\.data)
                    let offset = atoms
                        .reduce(into: 0) { partialResult, atom in
                            partialResult += Int(atom.offset)
                        }
                    let final = dataOfAtomsBefore.reduce(into: Data(), { partialResult, data in
                        partialResult.append(data)
                    }) + data
                    completion(.success((final, offset)))
                } catch {
                    completion(.failure(error))
                }
                return
            case .failure(let failure):
                completion(.failure(Mp4RestructureError.networkError(failure)))
            }
        }
    }
    
    private func urlForPartialContent(with url: URL, offset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.addValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        return urlRequest
    }
    
    private func checkIsOptimized(data: Data) -> (optimized: Bool, offset: Int?) {
        var isOptimized = true
        var possibleMoovOffset: Int?
        while offset < UInt64(data.count) {
            let atomSize = Int(readUInt32FromData(data: data, offset: offset))
            let atomType = Int(readUInt32FromData(data: data, offset: offset + 4))
            switch atomType {
            case Atoms.ftyp:
                let ftypData = data[Int(offset)..<atomSize]
                let ftyp = MP4Atom(type: atomType, size: atomSize, offset: offset, data: ftypData)
                self.ftyp = ftyp
                atoms.append(ftyp)
            case Atoms.mdat:
                let mdat = MP4Atom(type: atomType, size: atomSize, offset: offset)
                atoms.append(mdat)
                foundMdat = true
            case Atoms.moov:
                let moov = MP4Atom(type: atomType, size: atomSize, offset: offset)
                atoms.append(moov)
                foundMoov = true
            default:
                let atom = MP4Atom(type: atomType, size: atomSize, offset: offset)
                atoms.append(atom)
                break
            }
            if ftyp != nil {
                if foundMoov && !foundMdat {
                    print("file seems to be optimized")
                    isOptimized = true
                    possibleMoovOffset = nil
                } else if !foundMoov && foundMdat {
                    print("file is not optimized")
                    isOptimized = false
                    possibleMoovOffset = Int(offset) + atomSize
                }
            }
            offset += atomSize
        }
        return (isOptimized, possibleMoovOffset)
    }
    
    /// logic taken from qt-faststart.c over at ffmpeg
    /// https://github.com/FFmpeg/FFmpeg/blob/b47b2c5b912558b639c8542993e1256f9c69e675/tools/qt-faststart.c
    private func restructureMoov(data: Data) throws -> Data {
        let moovAtomSize = readAtomSize(data: data, offset: 0)
        let moovAtomType = readAtomType(data: data, offset: 4)
        guard moovAtomType == "moov" else {
            throw Mp4RestructureError.invalidMoovAtom
        }
        var originalBuffer = ByteBuffer(data: data)
        var moovAtom = ByteBuffer(size: moovAtomSize)
        
        if !readAndFill(&originalBuffer, &moovAtom) {
            return originalBuffer.storage
        }
        
        if try Int(moovAtom.getInteger(12) as UInt32) == Atoms.cmov {
            print("Compressed moov atom not supported")
            throw Mp4RestructureError.compressedAtomNotSupported
        }
        
        var atomType: Int
        var atomSize: Int
        
        // crawl through the atom and restructure offsets
        while(moovAtom.bytesAvailable >= 8) {
            let atomHead = moovAtom.offset
            atomType = Int(try moovAtom.getInteger(atomHead + 4) as UInt32)

            if !(atomType == Atoms.stco || atomType == Atoms.co64) {
                moovAtom.offset = moovAtom.offset + 1
                continue
            }
            
            atomSize = Int(try moovAtom.getInteger(atomHead) as UInt32)
            if atomSize > moovAtom.bytesAvailable {
                print("bad atom size")
                throw Mp4RestructureError.unableToRestructureData
            }
            // skip size (4 bytes), type (4 bytes), version (1 byte) and flags (3 bytes)
            moovAtom.offset = atomHead + 12
            if moovAtom.bytesAvailable < 4 {
                print("malformed atom")
                throw Mp4RestructureError.unableToRestructureData
            }
            
            let offsetCount = Int(try moovAtom.getInteger() as UInt32)
            if atomType == Atoms.stco {
                print("patching stco atom")
                if moovAtom.bytesAvailable < offsetCount * 4 {
                    print("bad atom size/element count")
                    throw Mp4RestructureError.unableToRestructureData
                }
                
                for _ in 0..<offsetCount {
                    let currentOffset = Int(try moovAtom.getInteger(moovAtom.offset) as UInt32)
                    
                    let newOffset = currentOffset + moovAtomSize
                    
                    if currentOffset < 0 && newOffset >= 0 {
                        print("Unsupported file exception")
                        throw Mp4RestructureError.unableToRestructureData
                    }
                    moovAtom.put(UInt32(newOffset).bigEndian)
                }
            } else if atomType == Atoms.co64 {
                print("patching co64 atom")
                if moovAtom.bytesAvailable < offsetCount * 8 {
                    print("bad atom size/element count")
                    throw Mp4RestructureError.unableToRestructureData
                }
                for _ in 0..<offsetCount {
                    let currentOffset: Int = try moovAtom.getInteger(moovAtom.offset)
                    moovAtom.put(currentOffset + moovAtomSize)
                }
             }
        }

        return moovAtom.storage
    }
    
    func readAndFill(_ data: inout ByteBuffer, _ buffer: inout ByteBuffer) -> Bool {
        buffer.clear()
        do {
            let slicedData: Data = try data.readBytes(buffer.length)
            buffer.writeBytes(slicedData)
            buffer.rewind()
            return true
        } catch {
            return false
        }
    }
    
    private func readAtomSize(data: Data, offset: UInt64) -> Int {
        guard offset + 4 < data.count else { return -1 }
        let sizeData = data.subdata(in: Int(offset)..<Int(offset + 4))
        return Int(UInt32(bigEndian: sizeData.withUnsafeBytes { $0.load(as: UInt32.self) }))
    }
    
    private func readAtomType(data: Data, offset: UInt64) -> String {
        guard offset + 4 < data.count else { return "Unknown" }
        let typeData = data.subdata(in: Int(offset)..<Int(offset + 4))
        return String(bytes: typeData, encoding: .ascii) ?? "Unknown"
    }
    
    private func readUInt32FromData(data: Data, offset: Int) -> UInt32 {
        let valueData = data.subdata(in: offset..<offset + 4)
        return UInt32(bigEndian: valueData.withUnsafeBytes { $0.load(as: UInt32.self) })
    }
}
