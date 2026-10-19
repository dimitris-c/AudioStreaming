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
    /// Time without any received data after which a request fails and is retried.
    /// Short enough to detect a dead connection (e.g. after a cell handover) while the buffer still plays.
    static let requestTimeoutInterval: TimeInterval = 15
    /// A stream that has not received data for this long is reopened when the network path changes.
    static let stallIntervalForPathChange: TimeInterval = 2

    public weak var delegate: AudioStreamSourceDelegate?

    public var position: Int {
        return seekOffset + relativePosition
    }

    public var length: Int {
        guard let parsedHeader = parsedHeaderOutput else { return 0 }
        return parsedHeader.fileLength
    }

    private let url: URL
    private let httpMethod: String?
    private let httpBody: Data?
    private let networkingClient: NetworkingClient
    private var streamRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]

    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int
    private var supportsSeek: Bool

    var metadataStreamProcessor: MetadataStreamSource

    private var shouldTryParsingIcycastHeaders: Bool = false
    private let icycastHeadersProcessor: IcycastHeadersProcessor

    public var audioFileHint: AudioFileTypeID {
        guard let output = parsedHeaderOutput, output.typeId != 0 else {
            return audioFileType(fileExtension: url.pathExtension)
        }
        return output.typeId
    }

    private let mp4Restructure: RemoteMp4Restructure

    public let underlyingQueue: DispatchQueue
    let streamOperationQueue: OperationQueue
    let netStatusService: NetStatusProvider
    var waitingForNetwork = false
    let retrierTimeout: Retrier

    private let receiveStateLock = UnfairLock()
    /// The time data was last received; `nil` while no stream request is open
    private var lastDataReceivedAt: DispatchTime?

    /// Length of the stream start kept to check that a reopened stream delivers the same content
    static let streamHeadLength = 4096
    /// The first bytes of the stream, to verify a resume without range support
    private var streamHead = Data()
    /// Progress of dropping the already read bytes after reopening a stream without range support
    private var resumeSkip: ResumeSkip?

    private struct ResumeSkip {
        let bytesToSkip: Int
        var received = 0
    }

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         icycastHeadersProcessor: IcycastHeadersProcessor,
         netStatusProvider: NetStatusProvider,
         retrier: Retrier,
         url: URL,
         httpMethod: String?,
         httpBody: Data?,
         underlyingQueue: DispatchQueue,
         httpHeaders: [String: String])
    {
        networkingClient = networking
        metadataStreamProcessor = metadataStreamSource
        self.url = url
        self.httpMethod = httpMethod
        self.httpBody = httpBody
        additionalRequestHeaders = httpHeaders
        relativePosition = 0
        seekOffset = 0
        supportsSeek = false
        netStatusService = netStatusProvider
        self.icycastHeadersProcessor = icycastHeadersProcessor
        self.underlyingQueue = underlyingQueue
        streamOperationQueue = OperationQueue()
        streamOperationQueue.underlyingQueue = underlyingQueue
        streamOperationQueue.maxConcurrentOperationCount = 1
        streamOperationQueue.isSuspended = true
        streamOperationQueue.name = "remote.audio.source.data.stream.queue"
        retrierTimeout = retrier
        mp4Restructure = RemoteMp4Restructure(url: url, networking: networkingClient)
        startNetworkService()
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     httpMethod: String?,
                     httpBody: Data?,
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
        setLastDataReceived(nil)
        retrierTimeout.cancel()
        streamOperationQueue.isSuspended = false
        streamOperationQueue.cancelAllOperations()
        if let streamTask = streamRequest {
            streamTask.cancel()
            networkingClient.remove(task: streamTask)
        }
        streamRequest = nil
    }

    public func seek(at offset: Int) {
        reopen(at: offset, skipping: 0)
    }

    /// - Parameter bytesToSkip: Bytes at the start of the stream the player has already read
    private func reopen(at offset: Int, skipping bytesToSkip: Int) {
        close()

        relativePosition = bytesToSkip
        seekOffset = offset
        resumeSkip = bytesToSkip > 0 ? ResumeSkip(bytesToSkip: bytesToSkip) : nil

        if !supportsSeek, offset != 0 {
            return
        }

        mp4Restructure.clear()
        retrierTimeout.cancel()
        metadataStreamProcessor.reset()
        icycastHeadersProcessor.reset()
        shouldTryParsingIcycastHeaders = false

        performOpen(seek: offset)
    }

    public func suspend() {
        streamOperationQueue.isSuspended = true
    }

    public func resume() {
        streamOperationQueue.isSuspended = false
    }

    // MARK: Private

    private func startNetworkService() {
        netStatusService.start { [weak self] connection in
            guard let self = self else { return }
            guard connection.isConnected else { return }
            if self.waitingForNetwork {
                self.reopenAtCurrentPosition()
                self.waitingForNetwork = false
            } else if self.isStreamStalled {
                // The path changed (new cell, interface or address) while no data arrived:
                // the open connection is most likely dead, so reopen it instead of waiting for the timeout
                self.reopenAtCurrentPosition()
            }
        }
    }

    private var isStreamStalled: Bool {
        receiveStateLock.withLock { () -> Bool in
            guard let lastDataReceivedAt else { return false }
            let elapsed = DispatchTime.now().uptimeNanoseconds - lastDataReceivedAt.uptimeNanoseconds
            return Double(elapsed) / Double(NSEC_PER_SEC) >= Self.stallIntervalForPathChange
        }
    }

    private func setLastDataReceived(_ time: DispatchTime?) {
        receiveStateLock.withLock {
            lastDataReceivedAt = time
        }
    }

    private func performOpen(seek seekOffset: Int) {
        if seekOffset == 0 {
            initialRequest { [weak self] in
                guard let self else { return }
                if self.parsedHeaderOutput?.isMp4 == true {
                    self.handleMp4Files()
                } else {
                    self.doPerfomOpen(seek: 0)
                }
            }
        } else {
            if mp4Restructure.dataOptimized {
                let adjustedOffset = mp4Restructure.seekAdjusted(offset: seekOffset)
                doPerfomOpen(seek: adjustedOffset)
            } else {
                doPerfomOpen(seek: seekOffset)
            }
        }
    }

    private func doPerfomOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        setLastDataReceived(.now())
        streamRequest = networkingClient.stream(request: urlRequest)
            .responseStream { [weak self] event in
                guard let self = self else { return }
                self.handleResponse(event: event)
            }
            .resume()

        metadataStreamProcessor.delegate = self
    }

    private func initialRequest(completion: @escaping () -> Void) {
        let urlRequest = fetchUrlForPartialContent(with: url)
        let task: NetworkDataStream = networkingClient.stream(request: urlRequest)
        task.responseStream { [weak self] event in
            switch event {
            case let .response(urlResponse):
                self?.parseResponseHeader(response: urlResponse)
                task.cancel()
                completion()
            case let .stream(.failure(error)):
                // No response (e.g. a timeout without network): retry, otherwise the stream never opens.
                // The cancellation above after a response also ends up here and is ignored.
                guard (error as? URLError)?.code != .cancelled else { return }
                self?.handleFailedStreamEvent(error: error)
            default:
                break
            }
        }.resume()
    }

    private func handleMp4Files() {
        mp4Restructure.optimizeIfNeeded { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(value):
                if let value {
                    self.addStreamOperation {
                        let audioCount = self.processAudio(data: value.initialData)
                        self.relativePosition += audioCount
                    }
                    self.doPerfomOpen(seek: value.mdatOffset)
                } else {
                    self.doPerfomOpen(seek: 0)
                }
            case let .failure(failure):
                self.delegate?.errorOccurred(source: self, error: failure)
            }
        }
    }

    // MARK: - Network Handle Methods

    private func handleResponse(event: NetworkDataStream.ResponseEvent) {
        switch event {
        case .response, .stream(.success):
            setLastDataReceived(.now())
        case .stream(.failure), .complete:
            setLastDataReceived(nil)
        }
        switch event {
        case let .response(urlResponse):
            parseResponseHeader(response: urlResponse)
            streamOperationQueue.isSuspended = false
        case let .stream(.success(response)):
            handleSuccessfulStreamEvent(response: response)
        case let .stream(.failure(error)):
            handleFailedStreamEvent(error: error)
        case let .complete(event):
            if let error = event.error {
                delegate?.errorOccurred(source: self, error: error)
            } else {
                addCompletionOperation { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.endOfFileOccurred(source: self)
                }
            }
        }
    }

    private func handleSuccessfulStreamEvent(response: NetworkDataStream.Response) {
        guard let audioData = response.data else {
            delegate?.errorOccurred(source: self, error: NetworkError.missingData)
            return
        }
        addStreamOperation { [weak self] in
            guard let self = self else { return }
            if self.shouldTryParsingIcycastHeaders {
                let (header, extractedAudio) = self.icycastHeadersProcessor.process(data: audioData)
                if let header = header {
                    self.shouldTryParsingIcycastHeaders = false
                    let parser = IcycastHeaderParser()
                    self.parsedHeaderOutput = parser.parse(input: header)
                    if let metadataStep = self.parsedHeaderOutput?.metadataStep {
                        self.metadataStreamProcessor.metadataAvailable(step: metadataStep)
                    }
                }
                let audioCount = self.processAudio(data: extractedAudio)
                self.relativePosition += audioCount
                return
            }
            guard let unreadData = self.dropAlreadyReadBytes(of: audioData) else { return }
            self.recordStreamHead(unreadData)
            let audioCount = self.processAudio(data: unreadData)
            self.relativePosition += audioCount
        }
    }

    /// While resuming a stream without range support, drops the bytes the player has already read,
    /// as long as the reopened stream starts with the same content.
    /// - Returns: The data to process, or `nil` if the whole chunk was dropped
    private func dropAlreadyReadBytes(of data: Data) -> Data? {
        guard var skip = resumeSkip else { return data }
        let compareEnd = min(streamHead.count, skip.bytesToSkip)
        if skip.received < compareEnd {
            let count = min(compareEnd - skip.received, data.count)
            let expected = streamHead.subdata(in: skip.received ..< skip.received + count)
            if Data(data.prefix(count)) != expected {
                // Different content (e.g. a live stream): play the new stream from its start
                resumeSkip = nil
                relativePosition = 0
                streamHead = Data()
                return data
            }
        }
        let dropCount = min(skip.bytesToSkip - skip.received, data.count)
        skip.received += dropCount
        resumeSkip = skip.received < skip.bytesToSkip ? skip : nil
        return dropCount < data.count ? Data(data.dropFirst(dropCount)) : nil
    }

    private func recordStreamHead(_ data: Data) {
        guard resumeSkip == nil, seekOffset == 0, streamHead.count == relativePosition,
              streamHead.count < Self.streamHeadLength else { return }
        streamHead.append(data.prefix(Self.streamHeadLength - streamHead.count))
    }

    private func handleFailedStreamEvent(error _: Error) {
        if !netStatusService.isConnected {
            waitingForNetwork = true
            return
        }
        waitingForNetwork = false
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
        parsedHeaderOutput = parser.parse(input: response)

        if parsedHeaderOutput == nil {
            shouldTryParsingIcycastHeaders = true
            checkHTTP(statusCode: httpStatusCode)
            return
        }

        if httpStatusCode == 206 {
            supportsSeek = true
        } else if let acceptRanges = parser.value(forHTTPHeaderField: HeaderField.acceptRanges, in: response) {
            supportsSeek = acceptRanges != "none"
        }

        // check to see if we have metadata to process
        if let metadataStep = parsedHeaderOutput?.metadataStep {
            metadataStreamProcessor.metadataAvailable(step: metadataStep)
        }
        checkHTTP(statusCode: httpStatusCode)
    }

    private func checkHTTP(statusCode: Int) {
        // check for error
        if statusCode == 416 { // range not satisfied error
            if length >= 0 { seekOffset = length }
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
        urlRequest.timeoutInterval = Self.requestTimeoutInterval
        urlRequest.httpMethod = httpMethod
        urlRequest.httpBody = httpBody

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if supportsSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)-", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    private func fetchUrlForPartialContent(with url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = Self.requestTimeoutInterval
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
        retrierTimeout.retry { [weak self] in
            guard let self = self else { return }
            self.reopenAtCurrentPosition()
        }
    }

    /// Reopens the stream after a network failure or stall, continuing where the player stopped reading
    private func reopenAtCurrentPosition() {
        if supportsSeek {
            seek(at: position)
        } else if canResumeBySkipping {
            // Without range support the stream starts over: drop the bytes already read
            reopen(at: 0, skipping: position)
        } else {
            seek(at: 0)
        }
    }

    private var canResumeBySkipping: Bool {
        position > 0
            && !metadataStreamProcessor.canProcessMetadata
            && !shouldTryParsingIcycastHeaders
            && !mp4Restructure.dataOptimized
            && streamHead.count >= min(position, Self.streamHeadLength)
    }

    // MARK: - Network Stream Operation Queue

    /// Schedules the given block on the stream operation queue
    ///
    /// - Parameter block: A closure to be executed
    private func addStreamOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.qualityOfService = .userInitiated
        streamOperationQueue.addOperation(operation)
    }

    /// Schedules the given block on the stream operation queue as a completion
    ///
    /// - Parameter block: A closure to be executed
    private func addCompletionOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.queuePriority = .veryLow
        streamOperationQueue.addOperation(operation)
    }
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String: String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        delegate?.metadataReceived(data: data)
    }
}
