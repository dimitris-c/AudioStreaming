//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import AVFoundation
import Foundation
import Network

enum RemoteAudioSourceError: Error {
    case mp4NotSeekable
}

public class RemoteAudioSource: AudioStreamSource {
    private static let compressedBufferHighWatermark = 1_048_576
    private static let compressedBufferLowWatermark = 524_288
    private static let drainByteQuantum = 262_144
    private static let drainChunkQuantum = 16

    private enum PendingTerminal {
        case endOfFile
        case failure(Error)
    }

    private enum DrainAction {
        case data(Data)
        case terminal(PendingTerminal)
        case stop
    }

    public weak var delegate: AudioStreamSourceDelegate?

    public var contentType: AudioContentType {
        stateLock.withLock {
            configuredContentType == .automatic ? inferredContentType : configuredContentType
        }
    }

    public var position: Int {
        stateLock.withLock {
            seekOffset + relativePosition
        }
    }

    public var length: Int {
        stateLock.withLock {
            parsedHeaderOutput?.fileLength ?? 0
        }
    }

    private let url: URL
    private let httpMethod: String?
    private let httpBody: Data?
    private let configuredContentType: AudioContentType
    private var inferredContentType: AudioContentType = .onDemand
    private let networkingClient: NetworkingClient
    private var streamRequest: NetworkDataStream?
    private var headerRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]

    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int
    private var supportsSeek: Bool

    var metadataStreamProcessor: MetadataStreamSource

    private var shouldTryParsingIcycastHeaders: Bool = false
    private let icycastHeadersProcessor: IcycastHeadersProcessor

    private let stateLock = UnfairLock()
    private let mailbox: CompressedDataMailbox<PendingTerminal>

    public var audioFileHint: AudioFileTypeID {
        stateLock.withLock {
            guard let output = parsedHeaderOutput, output.typeId != 0 else {
                return audioFileType(fileExtension: url.pathExtension)
            }
            return output.typeId
        }
    }

    private let mp4Restructure: RemoteMp4Restructure

    public let underlyingQueue: DispatchQueue
    let netStatusService: NetStatusProvider
    let retrierTimeout: Retrier
    private var waitingForNetwork = false
    private var reconnectLiveStreamOnResume = false
    private var consumerSuspendedOnPause = false
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private let queueSpecificValue: UInt8 = 1

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         icycastHeadersProcessor: IcycastHeadersProcessor,
         netStatusProvider: NetStatusProvider,
         retrier: Retrier,
         url: URL,
         httpMethod: String?,
         httpBody: Data?,
         contentType: AudioContentType = .automatic,
         underlyingQueue: DispatchQueue,
         httpHeaders: [String: String])
    {
        networkingClient = networking
        metadataStreamProcessor = metadataStreamSource
        self.url = url
        self.httpMethod = httpMethod
        self.httpBody = httpBody
        configuredContentType = contentType
        additionalRequestHeaders = httpHeaders
        relativePosition = 0
        seekOffset = 0
        supportsSeek = false
        netStatusService = netStatusProvider
        self.icycastHeadersProcessor = icycastHeadersProcessor
        self.underlyingQueue = underlyingQueue
        retrierTimeout = retrier
        mailbox = CompressedDataMailbox(
            highWatermark: Self.compressedBufferHighWatermark,
            lowWatermark: Self.compressedBufferLowWatermark
        )
        mp4Restructure = RemoteMp4Restructure(url: url, networking: networkingClient)
        underlyingQueue.setSpecific(key: queueSpecificKey, value: queueSpecificValue)
        startNetworkService()
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     httpMethod: String?,
                     httpBody: Data?,
                     contentType: AudioContentType = .automatic,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        let metadataParser = MetadataParser()
        let metadataProcessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        let netStatusProvider = NetStatusService(network: NWPathMonitor())
        let icyheaderProcessor = IcycastHeadersProcessor()
        let retrierTimeout = Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: nil)
        self.init(networking: networking,
                  metadataStreamSource: metadataProcessor,
                  icycastHeadersProcessor: icyheaderProcessor,
                  netStatusProvider: netStatusProvider,
                  retrier: retrierTimeout,
                  url: url,
                  httpMethod: httpMethod,
                  httpBody: httpBody,
                  contentType: contentType,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: httpHeaders)
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        self.init(networking: networking,
                  url: url,
                  httpMethod: nil,
                  httpBody: nil,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: httpHeaders)
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue)
    {
        self.init(networking: networking,
                  url: url,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: [:])
    }

    public func close() {
        let invalidation = invalidateCurrentStream(reconnectLiveStreamOnResume: false)
        invalidation.tasks.forEach(cancelAndRemove)
        mp4Restructure.clear()

        performOnUnderlyingQueue { [weak self] in
            guard let self, self.isCurrent(generation: invalidation.generation) else { return }
            self.retrierTimeout.cancel()
        }
    }

    public func seek(at offset: Int) {
        let invalidation = invalidateCurrentStream(
            seekOffset: offset,
            reconnectLiveStreamOnResume: false
        )
        invalidation.tasks.forEach(cancelAndRemove)
        mp4Restructure.clear()

        performOnUnderlyingQueue { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation: invalidation.generation) else { return }
            self.retrierTimeout.cancel()
            guard invalidation.canSeek else { return }

            self.metadataStreamProcessor.reset()
            self.icycastHeadersProcessor.reset()
            self.stateLock.withLock {
                self.shouldTryParsingIcycastHeaders = false
            }

            self.performOpen(seek: offset)
        }
    }

    public func suspend() {
        let shouldReconnectLiveStream = stateLock.withLock { () -> Bool in
            let contentType = configuredContentType == .automatic ? inferredContentType : configuredContentType
            guard contentType == .onDemand else { return true }
            mailbox.suspendConsumer()
            consumerSuspendedOnPause = true
            return false
        }

        if shouldReconnectLiveStream {
            let invalidation = invalidateCurrentStream(reconnectLiveStreamOnResume: true)
            invalidation.tasks.forEach(cancelAndRemove)
            mp4Restructure.clear()
            performOnUnderlyingQueue { [weak self] in
                guard let self, self.isCurrent(generation: invalidation.generation) else { return }
                self.retrierTimeout.cancel()
            }
            return
        }
    }

    public func resume() {
        let bufferedResume = stateLock.withLock { () -> (generation: UInt64, shouldScheduleDrain: Bool)? in
            guard consumerSuspendedOnPause else { return nil }
            consumerSuspendedOnPause = false
            let shouldScheduleDrain = mailbox.resumeConsumer()
            return (mailbox.generation, shouldScheduleDrain)
        }
        if let bufferedResume {
            if bufferedResume.shouldScheduleDrain {
                dispatchDrain(for: bufferedResume.generation)
            }
            return
        }

        guard contentType != .onDemand else { return }
        do {
            let generation = stateLock.withLock { () -> UInt64? in
                guard reconnectLiveStreamOnResume else { return nil }
                reconnectLiveStreamOnResume = false
                relativePosition = 0
                seekOffset = 0
                supportsSeek = false
                return mailbox.generation
            }
            guard let generation else { return }

            performOnUnderlyingQueue { [weak self] in
                guard let self, self.isCurrent(generation: generation) else { return }
                self.metadataStreamProcessor.reset()
                self.icycastHeadersProcessor.reset()
                self.stateLock.withLock {
                    self.parsedHeaderOutput = nil
                    self.shouldTryParsingIcycastHeaders = false
                }
                self.performOpen(seek: 0)
            }
            return
        }
    }

    // MARK: Private

    private func startNetworkService() {
        netStatusService.start { [weak self] connection in
            guard let self = self else { return }
            guard connection.isConnected else { return }
            let reconnectOffset = self.stateLock.withLock { () -> Int? in
                guard self.waitingForNetwork else { return nil }
                self.waitingForNetwork = false
                return self.supportsSeek ? self.seekOffset + self.relativePosition : 0
            }
            if let reconnectOffset {
                self.seek(at: reconnectOffset)
            }
        }
    }

    private func performOpen(seek seekOffset: Int) {
        let generation = currentGeneration()
        if seekOffset == 0 {
            initialRequest(generation: generation) { [weak self] in
                guard let self else { return }
                guard self.isCurrent(generation: generation) else { return }
                if self.stateLock.withLock(body: { self.parsedHeaderOutput?.isMp4 == true }) {
                    self.handleMp4Files(generation: generation)
                } else {
                    self.doPerfomOpen(seek: 0, generation: generation)
                }
            }
        } else {
            if mp4Restructure.dataOptimized {
                let adjustedOffset = mp4Restructure.seekAdjusted(offset: seekOffset)
                doPerfomOpen(seek: adjustedOffset, generation: generation)
            } else {
                doPerfomOpen(seek: seekOffset, generation: generation)
            }
        }
    }

    private func doPerfomOpen(seek seekOffset: Int, generation: UInt64) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        let stream = networkingClient.stream(request: urlRequest)
            .responseStream { [weak self] event in
                self?.handleResponse(event: event, generation: generation)
            }

        let shouldResume = stateLock.withLock { () -> Bool in
            guard generation == mailbox.generation else { return false }
            streamRequest = stream
            return true
        }
        guard shouldResume else {
            stream.cancel()
            networkingClient.remove(task: stream)
            return
        }

        metadataStreamProcessor.delegate = self
        stream.resume()
    }

    private func initialRequest(generation: UInt64, completion: @escaping () -> Void) {
        let urlRequest = fetchUrlForPartialContent(with: url)
        let task: NetworkDataStream = networkingClient.stream(request: urlRequest)
        let shouldResume = stateLock.withLock { () -> Bool in
            guard generation == mailbox.generation else { return false }
            headerRequest = task
            return true
        }
        guard shouldResume else {
            cancelAndRemove(task)
            return
        }

        task.responseStream { [weak self, weak task] event in
            guard let self, let task else { return }
            switch event {
            case let .response(urlResponse):
                self.underlyingQueue.async { [weak self] in
                    guard let self else { return }
                    guard self.detachHeaderRequest(task, generation: generation) else {
                        self.cancelAndRemove(task)
                        return
                    }
                    self.parseResponseHeader(response: urlResponse)
                    self.cancelAndRemove(task)
                    completion()
                }
            case let .stream(.failure(error)):
                guard self.detachHeaderRequest(task, generation: generation) else { return }
                self.cancelAndRemove(task)
                self.enqueueTerminal(.failure(error), generation: generation)
            case .stream, .complete:
                break
            }
        }.resume()
    }

    private func handleMp4Files(generation: UInt64) {
        mp4Restructure.optimizeIfNeeded { [weak self] result in
            guard let self else { return }
            self.underlyingQueue.async { [weak self] in
                guard let self else { return }
                guard self.isCurrent(generation: generation) else { return }
                switch result {
                case let .success(value):
                    if let value {
                        self.enqueueData(value.initialData, generation: generation)
                        self.doPerfomOpen(seek: value.mdatOffset, generation: generation)
                    } else {
                        self.doPerfomOpen(seek: 0, generation: generation)
                    }
                case let .failure(failure):
                    self.delegate?.errorOccurred(source: self, error: failure)
                }
            }
        }
    }

    // MARK: - Network Handle Methods

    private func handleResponse(event: NetworkDataStream.ResponseEvent, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }
        switch event {
        case let .response(urlResponse):
            underlyingQueue.async { [weak self] in
                guard let self, self.isCurrent(generation: generation) else { return }
                self.parseResponseHeader(response: urlResponse)
            }
        case let .stream(.success(response)):
            handleSuccessfulStreamEvent(response: response, generation: generation)
        case let .stream(.failure(error)):
            enqueueTerminal(.failure(error), generation: generation)
        case let .complete(event):
            if let error = event.error {
                enqueueTerminal(.failure(error), generation: generation)
            } else {
                enqueueTerminal(.endOfFile, generation: generation)
            }
        }
    }

    private func handleSuccessfulStreamEvent(response: NetworkDataStream.Response, generation: UInt64) {
        guard let audioData = response.data else {
            enqueueTerminal(.failure(NetworkError.missingData), generation: generation)
            return
        }
        enqueueData(audioData, generation: generation)
    }

    private func handleFailedStreamEvent(error _: Error) {
        if !netStatusService.isConnected {
            stateLock.withLock {
                waitingForNetwork = true
            }
            return
        }
        stateLock.withLock {
            waitingForNetwork = false
        }
        retryOnError()
    }

    /// Processing audio data, extracting metadata if needed.
    /// - Parameter data: The audio to be processed
    /// - Returns: An `Int` value representing the amount of audio data bytes.
    private func processAudio(data: Data) -> Int {
        if metadataStreamProcessor.canProcessMetadata {
            let extractedAudioData = metadataStreamProcessor.processMetadata(data: data)
            delegate?.dataAvailable(source: self, data: extractedAudioData)
            return extractedAudioData.count
        } else {
            delegate?.dataAvailable(source: self, data: data)
            return data.count
        }
    }

    private func parseResponseHeader(response: HTTPURLResponse?) {
        guard let response = response else { return }
        let httpStatusCode = response.statusCode
        let parser = HTTPHeaderParser()
        let parsedHeader = parser.parse(input: response)

        if parsedHeader == nil {
            stateLock.withLock {
                shouldTryParsingIcycastHeaders = true
            }
            checkHTTP(statusCode: httpStatusCode)
            return
        }

        stateLock.withLock {
            parsedHeaderOutput = parsedHeader
            if configuredContentType == .automatic {
                inferredContentType = parsedHeader?.contentTypeHint == .live ? .live : .onDemand
            }
            if httpStatusCode == 206 {
                supportsSeek = true
            } else if let acceptRanges = parser.value(forHTTPHeaderField: HeaderField.acceptRanges, in: response) {
                supportsSeek = acceptRanges != "none"
            }
        }

        // check to see if we have metadata to process
        if let metadataStep = parsedHeader?.metadataStep {
            metadataStreamProcessor.metadataAvailable(step: metadataStep)
        }
        checkHTTP(statusCode: httpStatusCode)
    }

    private func checkHTTP(statusCode: Int) {
        // check for error
        if statusCode == 416 { // range not satisfied error
            let streamLength = length
            stateLock.withLock {
                seekOffset = streamLength
            }
            delegate?.endOfFileOccurred(source: self)
        } else if statusCode >= 300 {
            delegate?.errorOccurred(
                source: self,
                error: NetworkError.serverError
            )
        }
    }

    private func buildUrlRequest(with url: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = httpBody

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let supportsRangeSeek = stateLock.withLock {
            supportsSeek
        }
        if supportsRangeSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)-", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    private func fetchUrlForPartialContent(with url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = httpBody

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.addValue("bytes=0-1", forHTTPHeaderField: "Range")
        return urlRequest
    }

    private func retryOnError() {
        let generation = currentGeneration()
        retrierTimeout.retry { [weak self] in
            guard let self = self else { return }
            guard self.isCurrent(generation: generation) else { return }
            let retryOffset = self.stateLock.withLock {
                self.supportsSeek ? self.seekOffset + self.relativePosition : 0
            }
            self.seek(at: retryOffset)
        }
    }

    // MARK: - Compressed Data Mailbox

    private func enqueueData(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }

        let result = stateLock.withLock { () -> CompressedDataMailbox<PendingTerminal>.EnqueueResult in
            let result = mailbox.enqueue(
                data,
                generation: generation,
                canSuspendTransport: streamRequest != nil
            )
            if result.shouldSuspendTransport {
                streamRequest?.suspend()
            }
            return result
        }

        if result.shouldScheduleDrain {
            dispatchDrain(for: generation)
        }
    }

    private func enqueueTerminal(_ terminal: PendingTerminal, generation: UInt64) {
        var completedTask: NetworkDataStream?
        let result = stateLock.withLock { () -> CompressedDataMailbox<PendingTerminal>.EnqueueResult in
            let result = mailbox.finish(terminal, generation: generation)
            if result.accepted {
                completedTask = streamRequest
                streamRequest = nil
            }
            return result
        }

        cancelAndRemove(completedTask)
        if result.shouldScheduleDrain {
            dispatchDrain(for: generation)
        }
    }

    private func dispatchDrain(for generation: UInt64) {
        underlyingQueue.async { [weak self] in
            self?.drainBufferedData(generation: generation)
        }
    }

    private func drainBufferedData(generation: UInt64) {
        var processedBytes = 0
        var processedChunks = 0

        while true {
            let action = stateLock.withLock { () -> DrainAction in
                switch mailbox.next(generation: generation) {
                case let .data(data):
                    return .data(data)
                case let .terminal(terminal):
                    return .terminal(terminal)
                case .stop:
                    return .stop
                }
            }

            switch action {
            case let .data(data):
                processBufferedData(data, generation: generation)

                stateLock.withLock {
                    if mailbox.completeData(byteCount: data.count, generation: generation) {
                        streamRequest?.resume()
                    }
                }

                processedBytes += data.count
                processedChunks += 1
                if processedBytes >= Self.drainByteQuantum
                    || processedChunks >= Self.drainChunkQuantum
                {
                    dispatchDrain(for: generation)
                    return
                }
            case let .terminal(terminal):
                handleTerminal(terminal, generation: generation)
                return
            case .stop:
                return
            }
        }
    }

    private func processBufferedData(_ data: Data, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }

        let shouldParseIcyHeaders = stateLock.withLock {
            shouldTryParsingIcycastHeaders
        }

        let audioCount: Int
        if shouldParseIcyHeaders {
            let (header, extractedAudio) = icycastHeadersProcessor.process(data: data)
            if let header {
                let parser = IcycastHeaderParser()
                let parsedHeader = parser.parse(input: header)
                stateLock.withLock {
                    shouldTryParsingIcycastHeaders = false
                    parsedHeaderOutput = parsedHeader
                    if configuredContentType == .automatic {
                        inferredContentType = parsedHeader?.contentTypeHint == .live ? .live : .onDemand
                    }
                }
                if let metadataStep = parsedHeader?.metadataStep {
                    metadataStreamProcessor.metadataAvailable(step: metadataStep)
                }
            }
            audioCount = processAudio(data: extractedAudio)
        } else {
            audioCount = processAudio(data: data)
        }

        stateLock.withLock {
            guard generation == mailbox.generation else { return }
            relativePosition += audioCount
        }
    }

    private func handleTerminal(_ terminal: PendingTerminal, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }
        switch terminal {
        case .endOfFile:
            delegate?.endOfFileOccurred(source: self)
        case let .failure(error):
            handleFailedStreamEvent(error: error)
        }
    }

    private func invalidateCurrentStream(
        seekOffset newSeekOffset: Int? = nil,
        reconnectLiveStreamOnResume: Bool
    ) -> (
        generation: UInt64,
        tasks: [NetworkDataStream],
        canSeek: Bool
    ) {
        stateLock.withLock {
            let canSeek = newSeekOffset.map { supportsSeek || $0 == 0 } ?? false
            let generation = mailbox.reset()
            waitingForNetwork = false
            self.reconnectLiveStreamOnResume = reconnectLiveStreamOnResume
            consumerSuspendedOnPause = false

            let currentTasks = [streamRequest, headerRequest].compactMap { $0 }
            streamRequest = nil
            headerRequest = nil
            if let newSeekOffset {
                relativePosition = 0
                seekOffset = newSeekOffset
            }
            return (generation, currentTasks, canSeek)
        }
    }

    private func detachHeaderRequest(_ task: NetworkDataStream, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == mailbox.generation, headerRequest === task else { return false }
            headerRequest = nil
            return true
        }
    }

    private func cancelAndRemove(_ task: NetworkDataStream?) {
        guard let task else { return }
        task.cancel()
        networkingClient.remove(task: task)
    }

    private func performOnUnderlyingQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) == queueSpecificValue {
            block()
        } else {
            underlyingQueue.async(execute: block)
        }
    }

    private func currentGeneration() -> UInt64 {
        stateLock.withLock {
            mailbox.generation
        }
    }

    private func isCurrent(generation: UInt64) -> Bool {
        stateLock.withLock {
            generation == mailbox.generation
        }
    }
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String: String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        delegate?.metadataReceived(data: data)
    }
}
