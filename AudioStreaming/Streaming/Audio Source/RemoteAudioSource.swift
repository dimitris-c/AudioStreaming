//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import AVFoundation
import Foundation
import Network

public class RemoteAudioSource: AudioStreamSource {
    weak var delegate: AudioStreamSourceDelegate?

    var position: Int {
        return seekOffset + relativePosition
    }

    var length: Int {
        guard let parsedHeader = parsedHeaderOutput else { return 0 }
        return parsedHeader.fileLength == 0 ? cachedFileLength : parsedHeader.fileLength
    }
    private var cachedFileLength: Int = 0

    private let url: URL
    private let networkingClient: NetworkingClient
    private var streamRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]

    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int

    internal var metadataStreamProcessor: MetadataStreamSource

    internal var audioFileHint: AudioFileTypeID {
        guard let output = parsedHeaderOutput, output.typeId != 0 else {
            return audioFileType(fileExtension: url.pathExtension)
        }
        return output.typeId
    }

    internal let underlyingQueue: DispatchQueue
    internal let streamOperationQueue: OperationQueue
    internal let netStatusService: NetStatusProvider
    internal var waitingForNetwork = false
    internal let retrierTimeout: Retrier

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         netStatusProvider: NetStatusProvider,
         retrier: Retrier,
         url: URL,
         underlyingQueue: DispatchQueue,
         httpHeaders: [String: String])
    {
        networkingClient = networking
        metadataStreamProcessor = metadataStreamSource
        self.url = url
        additionalRequestHeaders = httpHeaders
        relativePosition = 0
        seekOffset = 0
        netStatusService = netStatusProvider
        self.underlyingQueue = underlyingQueue
        streamOperationQueue = OperationQueue()
        streamOperationQueue.underlyingQueue = underlyingQueue
        streamOperationQueue.maxConcurrentOperationCount = 1
        streamOperationQueue.isSuspended = true
        streamOperationQueue.name = "remote.audio.source.data.stream.queue"
        retrierTimeout = retrier
        startNetworkService()
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        let metadataParser = MetadataParser()
        let metadataProcessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        let netStatusProvider = NetStatusService(network: NWPathMonitor())
        let retrierTimout = Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: nil)
        self.init(networking: networking,
                  metadataStreamSource: metadataProcessor,
                  netStatusProvider: netStatusProvider,
                  retrier: retrierTimout,
                  url: url,
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

    func close() {
        retrierTimeout.cancel()
        netStatusService.stop()
        streamOperationQueue.isSuspended = true
        streamOperationQueue.cancelAllOperations()
        if let streamTask = streamRequest {
            streamTask.cancel()
            networkingClient.remove(task: streamTask)
        }
        streamRequest = nil
    }

    func seek(at offset: Int) {
        close()

        relativePosition = 0
        seekOffset = offset

        if let supportsSeek = parsedHeaderOutput?.supportsSeek,
           !supportsSeek, offset != relativePosition
        {
            return
        }

        retrierTimeout.cancel()
        metadataStreamProcessor.reset()

        performOpen(seek: offset)
    }

    func suspend() {
        streamRequest?.suspend()
        streamOperationQueue.isSuspended = true
    }

    func resume() {
        streamRequest?.resume()
        streamOperationQueue.isSuspended = false
    }

    // MARK: Private

    private func startNetworkService() {
        netStatusService.start { [weak self] connection in
            guard let self = self else { return }
            guard connection.isConnected else { return }
            if self.waitingForNetwork {
                self.waitingForNetwork = false
                self.seek(at: self.position)
            }
        }
    }

    private func performOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)

        let request = networkingClient.stream(request: urlRequest)
            .responseStream { [weak self] event in
                guard let self = self else { return }
                self.handleResponse(event: event)
            }
            .resume()

        streamRequest = request
        metadataStreamProcessor.delegate = self
    }

    // MARK: - Network Handle Methods

    private func handleResponse(event: NetworkDataStream.ResponseEvent) {
        switch event {
        case let .response(urlResponse):
            parseResponseHeader(response: urlResponse)
            streamOperationQueue.isSuspended = false
        case let .stream(event):
            handleStreamEvent(event: event)
        case let .complete(event):
            if let error = event.error {
                delegate?.errorOccured(source: self, error: error)
            } else {
                addCompletionOperation { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.endOfFileOccured(source: self)
                }
            }
        }
    }

    private func handleStreamEvent(event: NetworkDataStream.StreamResult) {
        switch event {
        case let .success(value):
            if let data = value.data {
                addStreamOperation { [weak self] in
                    guard let self = self else { return }
                    if self.metadataStreamProcessor.canProccessMetadata {
                        let extractedAudioData = self.metadataStreamProcessor.proccessMetadata(data: data)
                        self.delegate?.dataAvailable(source: self, data: extractedAudioData)
                    } else {
                        self.delegate?.dataAvailable(source: self, data: data)
                    }
                    self.relativePosition += data.count
                }
            }
        case .failure:
            if !netStatusService.isConnected {
                waitingForNetwork = true
                return
            }
            waitingForNetwork = false
            retryOnError()
        }
    }

    private func parseResponseHeader(response: HTTPURLResponse?) {
        guard let response = response else { return }
        let httpStatusCode = response.statusCode
        let parser = HTTPHeaderParser()
        parsedHeaderOutput = parser.parse(input: response)
        if cachedFileLength == 0 {
            cachedFileLength = parsedHeaderOutput?.fileLength ?? 0
        }
        // check to see if we have metadata to proccess
        if let metadataStep = parsedHeaderOutput?.metadataStep {
            metadataStreamProcessor.metadataAvailable(step: metadataStep)
        }
        // check for error
        if httpStatusCode == 416 { // range not satisfied error
            if length >= 0 { seekOffset = length }
            delegate?.endOfFileOccured(source: self)
        } else if httpStatusCode >= 300 {
            delegate?.errorOccured(source: self, error: NetworkError.serverError)
        }
    }

    private func buildUrlRequest(with url: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if let supportsSeek = parsedHeaderOutput?.supportsSeek, supportsSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)-", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    private func retryOnError() {
        retrierTimeout.retry { [weak self] in
            guard let self = self else { return }
            self.seek(at: self.position)
        }
    }

    // MARK: - Network Stream Operation Queue

    /// Schedules the given block on the stream operation queue
    ///
    /// - Parameter block: A closure to be executed
    private func addStreamOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
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

