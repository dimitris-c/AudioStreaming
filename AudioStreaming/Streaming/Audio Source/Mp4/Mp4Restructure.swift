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
        guard value >= 0, value <= 0xFFFF_FFFF else {
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
    case missingMdatAtom
    case missingMoovAtom
    case compressedAtomNotSupported
    case nonOptimizedMp4AndServerCannotSeek
    case networkError(Error)
}

final class Mp4Restructure {
    struct RestructuredData {
        var initialData: Data
        var mdatOffset: Int
    }

    private var audioData: Data

    private var atomOffset: Int = 0
    private var atoms: [MP4Atom] = []
    private var ftyp: MP4Atom?
    private var foundMoov = false
    private var foundMdat = false

    private var task: NetworkDataStream?

    private(set) var dataOptimized: Bool = false

    private var moovAtomSize: Int = 0

    private let url: URL
    private let networking: NetworkingClient

    init(url: URL, networking: NetworkingClient) {
        self.url = url
        self.networking = networking
        self.audioData = Data()
    }

    func clear() {
        atomOffset = 0
        audioData = Data()
    }

    deinit {
        audioData = Data()
        task?.cancel()
        task = nil
    }

    /// Adjust the seekOffset of subtracting the moovAtomSize
    /// - Parameter offset: A byte offset
    /// - Returns: An adjusted byte offset
    func seekAdjusted(offset: Int) -> Int {
        offset - moovAtomSize
    }

    ///
    /// Gather audio and parse along the way, if moov atom is found, continue as usual
    /// if mdat is found before moov:
    ///  - Get mdat size and make a byte request Range: bytes=mdatAtomSize- for possible moov atom
    ///  - once the request is complete search for an moov atom and restructure it
    ///  - finally, make a byte request Range: bytes=mdatOffset- to get the mdat
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
                        self.audioData = Data()
                        completion(.failure(Mp4RestructureError.unableToRestructureData))
                        return
                    }
                    self.audioData.append(data)
                    let value = self.checkIsOptimized(data: self.audioData)
                    if let value {
                        if let offset = value.offset, !value.optimized {
                            guard response.response?.statusCode == 206 else {
                                Logger.error("⛔️ mp4 error: no moov before mdat and the stream is not seekable", category: .networking)
                                completion(.failure(Mp4RestructureError.nonOptimizedMp4AndServerCannotSeek))
                                return
                            }
                            // stop request, fetch moov and restructure
                            self.audioData = Data()
                            self.task?.cancel()
                            self.task = nil
                            self.fetchAndRestructureMoovAtom(offset: offset) { result in
                                switch result {
                                case let .success(value):
                                    let data = value.data
                                    let offset = value.offset
                                    self.dataOptimized = true
                                    completion(.success(RestructuredData(initialData: data, mdatOffset: offset)))
                                case let .failure(error):
                                    completion(.failure(Mp4RestructureError.networkError(error)))
                                }
                            }
                        } else {
                            self.audioData = Data()
                            self.task?.cancel()
                            self.task = nil
                            completion(.success(nil))
                        }
                    }
                case let .stream(.failure(error)):
                    completion(.failure(Mp4RestructureError.networkError(error)))
                case .complete:
                    break
                }
            }
        task?.resume()
    }

    func fetchAndRestructureMoovAtom(offset: Int, completion: @escaping (Result<(data: Data, offset: Int), Error>) -> Void) {
        networking.task(request: urlForPartialContent(with: url, offset: offset)) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(data):
                do {
                    let (initialData, mdatOffset) = try self.restructureMoov(data: data)
                    completion(.success((initialData, mdatOffset)))
                } catch {
                    completion(.failure(error))
                }
            case let .failure(failure):
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

    private func restructureMoov(data: Data) throws -> (initialData: Data, mdatOffset: Int) {
        let (atomData, moovSize) = try doRestructureMoov(data: data)
        moovAtomSize = moovSize
        guard let mdatIndex = atoms.firstIndex(where: { $0.type == Atoms.mdat }) else {
            throw Mp4RestructureError.missingMdatAtom
        }
        let mdatAtom = atoms[mdatIndex]
        let atoms = Array(atoms[..<mdatIndex])
        let dataOfAtomsBefore = atoms.filter { $0.data != nil }.compactMap(\.data)
        let accumulatedInitialData = dataOfAtomsBefore.reduce(into: Data()) { partialResult, data in
            partialResult.append(data)
        }
        let initialData = accumulatedInitialData + atomData
        let mdatOffset = mdatAtom.offset - Atoms.atomPreampleSize
        return (initialData, mdatOffset)
    }

    private func checkIsOptimized(data: Data) -> (optimized: Bool, offset: Int?)? {
        while atomOffset < UInt64(data.count) {
            let atomSize = Int(readUInt32FromData(data: data, offset: atomOffset))
            let atomType = Int(readUInt32FromData(data: data, offset: atomOffset + 4))
            switch atomType {
            case Atoms.ftyp:
                let ftypData = data[Int(atomOffset) ..< atomSize]
                let ftyp = MP4Atom(type: atomType, size: atomSize, offset: atomOffset, data: ftypData)
                self.ftyp = ftyp
                atoms.append(ftyp)
            case Atoms.mdat:
                let mdat = MP4Atom(type: atomType, size: atomSize, offset: atomOffset)
                atoms.append(mdat)
                foundMdat = true
            case Atoms.moov:
                let moov = MP4Atom(type: atomType, size: atomSize, offset: atomOffset)
                atoms.append(moov)
                foundMoov = true
            default:
                let atom = MP4Atom(type: atomType, size: atomSize, offset: atomOffset)
                atoms.append(atom)
            }
            if ftyp != nil {
                if foundMoov && !foundMdat {
                    Logger.debug("🕵️ detected an optimized mp4", category: .generic)
                    return (true, nil)
                } else if !foundMoov && foundMdat {
                    Logger.debug("🕵️ detected an non-optimized mp4", category: .generic)
                    let possibleMoovOffset = Int(atomOffset) + atomSize
                    return (false, possibleMoovOffset)
                }
            }
            atomOffset += atomSize
        }
        return nil
    }

    /// logic taken from qt-faststart.c over at ffmpeg
    /// https://github.com/FFmpeg/FFmpeg/blob/b47b2c5b912558b639c8542993e1256f9c69e675/tools/qt-faststart.c
    private func doRestructureMoov(data: Data) throws -> (Data, Int) {
        var moovAtomSize: Int = 0
        var moovAtomType: Int = 0
        var originalData = ByteBuffer(data: data)
        var offset: Int = 0
        // do search for moov within the new data
        while offset < originalData.length {
            moovAtomSize = Int(try originalData.getInteger() as UInt32)
            moovAtomType = Int(try originalData.getInteger() as UInt32)

            if moovAtomType == Atoms.moov {
                break
            }
            offset += moovAtomSize
        }

        // error if we couldn't find an moov type
        guard moovAtomType == Atoms.moov else {
            throw Mp4RestructureError.missingMoovAtom
        }

        originalData.offset = offset
        var moovAtom = ByteBuffer(size: moovAtomSize)
        let slicedData: Data = try originalData.readBytes(moovAtom.length)
        moovAtom.writeBytes(slicedData)
        moovAtom.rewind()

        if try Int(moovAtom.getInteger(12) as UInt32) == Atoms.cmov {
            Logger.debug("Compressed moov atom not supported", category: .generic)
            throw Mp4RestructureError.compressedAtomNotSupported
        }

        var atomType: Int
        var atomSize: Int

        // crawl through the atom and restructure offsets
        while moovAtom.bytesAvailable >= 8 {
            let atomHead = moovAtom.offset
            atomType = try Int(moovAtom.getInteger(atomHead + 4) as UInt32)

            if !(atomType == Atoms.stco || atomType == Atoms.co64) {
                moovAtom.offset += 1
                continue
            }

            atomSize = try Int(moovAtom.getInteger(atomHead) as UInt32)
            if atomSize > moovAtom.bytesAvailable {
                Logger.debug("aborting due to a bad size on an atom", category: .generic)
                throw Mp4RestructureError.unableToRestructureData
            }
            // we need to skip the offset by `12` which come from the bytes of [size/4][type/4][version/1][flags/3]
            // more info https://developer.apple.com/documentation/quicktime-file-format/chunk_offset_atom
            moovAtom.offset = atomHead + 12
            if moovAtom.bytesAvailable < 4 {
                Logger.debug("aborting due to a malformed atom", category: .generic)
                throw Mp4RestructureError.unableToRestructureData
            }

            // the next integer determines the `Number of entries`
            // https://developer.apple.com/documentation/quicktime-file-format/chunk_offset_atom/number_of_entries
            let numberOfOffsetEntries = try Int(moovAtom.getInteger() as UInt32)
            if atomType == Atoms.stco {
                Logger.debug("🏗️ patching stco atom...", category: .generic)
                if moovAtom.bytesAvailable < numberOfOffsetEntries * 4 {
                    Logger.debug("aborting due to bad atom..", category: .generic)
                    throw Mp4RestructureError.unableToRestructureData
                }

                for _ in 0 ..< numberOfOffsetEntries {
                    let currentOffset = try Int(moovAtom.getInteger(moovAtom.offset) as UInt32)
                    // adjust the offset by adding the size of moov atom
                    let adjustOffset = currentOffset + moovAtomSize

                    if currentOffset < 0, adjustOffset >= 0 {
                        throw Mp4RestructureError.unableToRestructureData
                    }
                    moovAtom.put(UInt32(adjustOffset).bigEndian)
                }
            } else if atomType == Atoms.co64 {
                Logger.debug("🏗️ patching co64 atom...", category: .generic)
                if moovAtom.bytesAvailable < numberOfOffsetEntries * 8 {
                    Logger.debug("aborting due to bad atom..", category: .generic)
                    throw Mp4RestructureError.unableToRestructureData
                }
                for _ in 0 ..< numberOfOffsetEntries {
                    let currentOffset: Int = try moovAtom.getInteger(moovAtom.offset)
                    // adjust the offset by adding the size of moov atom
                    moovAtom.put(currentOffset + moovAtomSize)
                }
            }
        }
        return (moovAtom.storage, moovAtomSize)
    }

    private func readUInt32FromData(data: Data, offset: Int) -> UInt32 {
        let valueData = data.subdata(in: offset ..< offset + 4)
        return UInt32(bigEndian: valueData.withUnsafeBytes { $0.load(as: UInt32.self) })
    }
}
