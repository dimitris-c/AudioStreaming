//
//  Created by Dimitrios Chatzieleftheriou on 10/03/2024.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import OSLog

final class RemoteMp4Restructure {
    struct RestructuredData {
        var initialData: Data
        var mdatOffset: Int
    }

    private enum OptimizationDecision {
        case none
        case complete(Result<RestructuredData?, Error>, taskToCancel: NetworkDataStream?)
        case fetchMoov(offset: Int, taskToCancel: NetworkDataStream?)
    }

    private let stateLock = UnfairLock()
    private var audioData: Data

    private var task: NetworkDataStream?
    private var restructureTask: URLSessionDataTask?
    private var generation: UInt64 = 0

    private var _dataOptimized: Bool = false

    var dataOptimized: Bool {
        stateLock.withLock {
            _dataOptimized
        }
    }

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
        let tasks = stateLock.withLock { () -> (NetworkDataStream?, URLSessionDataTask?) in
            generation &+= 1
            mp4Restructure.clear()
            audioData = Data()

            let tasks = (task, restructureTask)
            task = nil
            restructureTask = nil
            return tasks
        }

        if let task = tasks.0 {
            task.cancel()
            networking.remove(task: task)
        }
        tasks.1?.cancel()
    }

    /// Adjust the seekOffset of subtracting the moovAtomSize
    /// - Parameter offset: A byte offset
    /// - Returns: An adjusted byte offset
    func seekAdjusted(offset: Int) -> Int {
        stateLock.withLock {
            mp4Restructure.seekAdjusted(offset: offset)
        }
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
        let generation = stateLock.withLock { self.generation }
        let stream = networking.stream(request: urlForPartialContent(with: url, offset: 0))
        let shouldResume = stateLock.withLock { () -> Bool in
            guard generation == self.generation else { return false }
            task = stream
            return true
        }

        guard shouldResume else {
            stream.cancel()
            networking.remove(task: stream)
            return
        }

        stream.responseStream { [weak self] event in
            self?.handleOptimizationEvent(event, generation: generation, completion: completion)
        }
        stream.resume()
    }

    private func handleOptimizationEvent(
        _ event: NetworkDataStream.ResponseEvent,
        generation: UInt64,
        completion: @escaping (Result<RestructuredData?, Error>) -> Void
    ) {
        switch event {
        case .response:
            break
        case let .stream(.success(response)):
            handleOptimizationData(response, generation: generation, completion: completion)
        case let .stream(.failure(error)):
            let shouldComplete = stateLock.withLock { () -> Bool in
                guard generation == self.generation else { return false }
                task = nil
                audioData = Data()
                return true
            }
            guard shouldComplete else { return }

            let nsError = error as NSError
            guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else {
                return
            }
            completion(.failure(Mp4RestructureError.networkError(error)))
        case .complete:
            let shouldComplete = stateLock.withLock { () -> Bool in
                guard generation == self.generation else { return false }
                task = nil
                audioData = Data()
                return true
            }
            if shouldComplete {
                completion(.failure(Mp4RestructureError.unableToRestructureData))
            }
        }
    }

    private func handleOptimizationData(
        _ response: NetworkDataStream.Response,
        generation: UInt64,
        completion: @escaping (Result<RestructuredData?, Error>) -> Void
    ) {
        let decision = stateLock.withLock { () -> OptimizationDecision in
            guard generation == self.generation else { return .none }
            guard let data = response.data else {
                let taskToCancel = detachCurrentTask()
                audioData = Data()
                return .complete(
                    .failure(Mp4RestructureError.unableToRestructureData),
                    taskToCancel: taskToCancel
                )
            }

            audioData.append(data)
            do {
                switch try mp4Restructure.checkIsOptimized(data: audioData) {
                case .undetermined:
                    return .none
                case .optimized:
                    audioData = Data()
                    return .complete(.success(nil), taskToCancel: detachCurrentTask())
                case let .needsRestructure(moovOffset):
                    guard response.response?.statusCode == 206 else {
                        Logger.error("⛔️ mp4 error: no moov before mdat and the stream is not seekable", category: .networking)
                        return .complete(
                            .failure(Mp4RestructureError.nonOptimizedMp4AndServerCannotSeek),
                            taskToCancel: detachCurrentTask()
                        )
                    }
                    audioData = Data()
                    return .fetchMoov(offset: moovOffset, taskToCancel: detachCurrentTask())
                }
            } catch {
                audioData = Data()
                return .complete(
                    .failure(Mp4RestructureError.invalidAtomSize),
                    taskToCancel: detachCurrentTask()
                )
            }
        }

        switch decision {
        case .none:
            break
        case let .complete(result, taskToCancel):
            cancelAndRemove(taskToCancel)
            completion(result)
        case let .fetchMoov(offset, taskToCancel):
            cancelAndRemove(taskToCancel)
            fetchAndRestructureMoovAtom(offset: offset, generation: generation, completion: completion)
        }
    }

    private func fetchAndRestructureMoovAtom(
        offset: Int,
        generation: UInt64,
        completion: @escaping (Result<RestructuredData?, Error>) -> Void
    ) {
        let task = networking.task(request: urlForPartialContent(with: url, offset: offset)) { [weak self] result in
            guard let self else { return }
            let completionResult = self.stateLock.withLock { () -> Result<RestructuredData?, Error>? in
                guard generation == self.generation else { return nil }
                self.restructureTask = nil

                switch result {
                case let .success(data):
                    do {
                        let (initialData, mdatOffset) = try self.mp4Restructure.restructureMoov(data: data)
                        self._dataOptimized = true
                        return .success(RestructuredData(initialData: initialData, mdatOffset: mdatOffset))
                    } catch {
                        return .failure(error)
                    }
                case let .failure(error):
                    return .failure(Mp4RestructureError.networkError(error))
                }
            }
            if let completionResult {
                completion(completionResult)
            }
        }

        let shouldCancel = stateLock.withLock { () -> Bool in
            guard generation == self.generation else { return true }
            restructureTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    // removed warmup range helper

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

    private func detachCurrentTask() -> NetworkDataStream? {
        let task = self.task
        self.task = nil
        return task
    }

    private func cancelAndRemove(_ task: NetworkDataStream?) {
        guard let task else { return }
        task.cancel()
        networking.remove(task: task)
    }
}
