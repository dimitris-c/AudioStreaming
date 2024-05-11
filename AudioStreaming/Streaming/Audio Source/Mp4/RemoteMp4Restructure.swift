//
//  Created by Dimitrios Chatzieleftheriou on 10/03/2024.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class RemoteMp4Restructure {
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

    private let mp4Restructure: Mp4Restructure

    init(url: URL, networking: NetworkingClient, restructure: Mp4Restructure = Mp4Restructure()) {
        self.url = url
        self.networking = networking
        self.audioData = Data()
        self.mp4Restructure = restructure
    }

    func clear() {
        mp4Restructure.clear()
        audioData = Data()
        task?.cancel()
        task = nil
    }

    /// Adjust the seekOffset of subtracting the moovAtomSize
    /// - Parameter offset: A byte offset
    /// - Returns: An adjusted byte offset
    func seekAdjusted(offset: Int) -> Int {
        mp4Restructure.seekAdjusted(offset: offset)
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
                    do {
                        let value = try self.mp4Restructure.checkIsOptimized(data: self.audioData)
                        if let value {
                            guard response.response?.statusCode == 206 else {
                                Logger.error("⛔️ mp4 error: no moov before mdat and the stream is not seekable", category: .networking)
                                completion(.failure(Mp4RestructureError.nonOptimizedMp4AndServerCannotSeek))
                                return
                            }
                            // stop request, fetch moov and restructure
                            self.audioData = Data()
                            self.task?.cancel()
                            self.task = nil
                            self.fetchAndRestructureMoovAtom(offset: value.moovOffset) { result in
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
                    } catch {
                        completion(.failure(Mp4RestructureError.invalidAtomSize))
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
                    let (initialData, mdatOffset) = try self.mp4Restructure.restructureMoov(data: data)
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
}
