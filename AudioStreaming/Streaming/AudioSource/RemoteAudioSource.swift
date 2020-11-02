//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import Foundation

public class RemoteAudioSource: AudioStreamSource {
    weak var delegate: AudioStreamSourceDelegate?

    var position: Int {
        return seekOffset + relativePosition
    }

    var length: Int {
        guard let parsedHeader = parsedHeaderOutput else { return 0 }
        return parsedHeader.fileLength
    }

    private let url: URL
    private let networkingClient: NetworkingClient
    private var streamRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]

    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int

    internal var metadataStreamProcessor: MetadataStreamSource

    internal var audioFileHint: AudioFileTypeID {
        guard let output = parsedHeaderOutput else {
            return audioFileType(fileExtension: url.pathExtension)
        }
        return output.typeId
    }

    internal let underlyingQueue: DispatchQueue
    internal let streamOperationQueue: OperationQueue
    private var streamOperations: [BlockOperation] = []

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
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
        self.underlyingQueue = underlyingQueue
        streamOperationQueue = OperationQueue()
        streamOperationQueue.underlyingQueue = underlyingQueue
        streamOperationQueue.maxConcurrentOperationCount = 1
        streamOperationQueue.isSuspended = true
        streamOperationQueue.name = "remote.audio.source.data.stream.queue"
    }

    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String])
    {
        let metadataParser = MetadataParser()
        let metadataProcessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        self.init(networking: networking,
                  metadataStreamSource: metadataProcessor,
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
            addStreamOperation { [weak self] in
                self?.handleStreamEvent(event: event)
            }
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
                if metadataStreamProcessor.canProccessMetadata {
                    let extractedAudioData = metadataStreamProcessor.proccessMetadata(data: data)
                    delegate?.dataAvailable(source: self, data: extractedAudioData)
                } else {
                    delegate?.dataAvailable(source: self, data: data)
                }
                relativePosition += data.count
            }
        case let .failure(error):
            delegate?.errorOccured(source: self, error: error)
        }
    }

    private func parseResponseHeader(response: HTTPURLResponse?) {
        guard let response = response else { return }
        let httpStatusCode = response.statusCode
        let parser = HTTPHeaderParser()
        parsedHeaderOutput = parser.parse(input: response)
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
        urlRequest.timeoutInterval = 30

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")

        if let supportsSeek = parsedHeaderOutput?.supportsSeek, supportsSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)-", forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    // MARK: - Network Stream Operation Queue

    /// Schedules the given block on the stream operation queue
    ///
    /// - Parameter block: A closure to be executed
    private func addStreamOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.name = "stream.op.\(streamOperations.count)"
        if let lastOp = streamOperations.last {
            operation.addDependency(lastOp)
        }
        streamOperationQueue.addOperation(operation)
        streamOperations.append(operation)
    }

    /// Schedules the given block on the stream operation queue as a completion
    ///
    /// - Parameter block: A closure to be executed
    private func addCompletionOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.name = "stream.completion.op"
        if let lastOperation = streamOperations.last {
            operation.addDependency(lastOperation)
        }
        streamOperationQueue.addOperation(operation)
        streamOperations = []
    }
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String: String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        delegate?.metadataReceived(data: data)
    }
}
