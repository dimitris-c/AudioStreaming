//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AudioToolbox

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
    private let networking: NetworkingClient
    private var streamRequest: NetworkDataStream?
    
    private var additionalRequestHeaders: [String: String]
    
    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int
    
    internal var metadataStreamProccessor: MetadataStreamSource
    
    internal var audioFileHint: AudioFileTypeID {
        if let output = parsedHeaderOutput {
            return output.typeId
        }
        return audioFileType(fileExtension: self.url.pathExtension)
    }
    
    internal let underlyingQueue: DispatchQueue
    internal let networkStreamQueue: OperationQueue
    
    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         url: URL,
         underlyingQueue: DispatchQueue,
         httpHeaders: [String: String]) {
        self.networking = networking
        self.metadataStreamProccessor = metadataStreamSource
        self.url = url
        self.additionalRequestHeaders = httpHeaders
        self.relativePosition = 0
        self.seekOffset = 0
        self.underlyingQueue = underlyingQueue
        self.networkStreamQueue = OperationQueue()
        self.networkStreamQueue.underlyingQueue = underlyingQueue
        self.networkStreamQueue.maxConcurrentOperationCount = 1
        self.networkStreamQueue.isSuspended = true
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue,
                     httpHeaders: [String: String]) {
        let metadataParser = MetadataParser()
        let metadataProccessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        self.init(networking: networking,
                  metadataStreamSource: metadataProccessor,
                  url: url,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: httpHeaders)
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     underlyingQueue: DispatchQueue) {
        self.init(networking: networking,
                  url: url,
                  underlyingQueue: underlyingQueue,
                  httpHeaders: [:])
    }
    
    func close() {
        streamRequest?.cancel()
        if let streamTask = streamRequest {
            networking.remove(task: streamTask)
        }
        streamRequest = nil
        networkStreamQueue.cancelAllOperations()
    }
    
    func seek(at offset: Int) {
        close()
        
        relativePosition = 0
        seekOffset = offset
        
        if let supportsSeek = parsedHeaderOutput?.supportsSeek,
           !supportsSeek && offset != relativePosition  {
            return
        }
        
        resume()
        performOpen(seek: offset)
    }
    
    func suspend() {
        networkStreamQueue.isSuspended = true
    }
    
    func resume() {
        networkStreamQueue.isSuspended = false
    }
    
    // MARK: Private
    
    private func performOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        
        streamRequest = networking.stream(request: urlRequest)
            .responseStream { [weak self] event in
                guard let self = self else { return }
                self.handleResponse(event: event)
            }
        streamRequest?.resume()
        metadataStreamProccessor.delegate = self
    }
    
    // MARK: - Network Handle Methods
    
    private func handleResponse(event: NetworkDataStream.StreamEvent) {
        switch event {
            case .response(let urlResponse):
                parseResponseHeader(response: urlResponse)
            case .stream(let event):
                addStreamOperation { [weak self] in
                    self?.handleStreamEvent(event: event)
                }
            case .complete(let event):
                addCompletionOperation { [weak self] in
                    guard let self = self else { return }
                    if let error = event.error {
                        self.delegate?.errorOccured(source: self, error: error)
                    } else {
                        self.delegate?.endOfFileOccured(source: self)
                    }
                }
        }
    }

    private func handleStreamEvent(event: NetworkDataStream.StreamResult) {
        switch event {
            case .success(let value):
                if let data = value.data {
                    if metadataStreamProccessor.canProccessMetadata {
                        let extractedAudioData = metadataStreamProccessor.proccessMetadata(data: data)
                        delegate?.dataAvailable(source: self, data: extractedAudioData)
                    } else {
                        delegate?.dataAvailable(source: self, data: data)
                    }
                    relativePosition += data.count
                }
            case .failure(let error):
                delegate?.errorOccured(source: self, error: error)
                break
        }
    }
    
    private func parseResponseHeader(response: HTTPURLResponse?) {
        guard let response = response else { return }
        // TODO: Parse Icy header
        let httpStatusCode = response.statusCode
        let parser = HTTPHeaderParser()
        parsedHeaderOutput = parser.parse(input: response)
        // parse the header response
        // check to see if we have metadata to proccess
        if let metadataStep = parsedHeaderOutput?.metadataStep {
            metadataStreamProccessor.metadataAvailable(step: metadataStep)
        }
        // check for error
        if httpStatusCode == 416 { // range not satisfied error
            if length >= 0 { seekOffset = self.length }
            delegate?.endOfFileOccured(source: self)
        }
        else if httpStatusCode >= 300 {
            delegate?.errorOccured(source: self, error: NetworkError.serverError)
        }
        
    }
    
    private func buildUrlRequest(with url: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 30
        
        for header in self.additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-MetaData")
        
        if let supportsSeek = self.parsedHeaderOutput?.supportsSeek, supportsSeek && seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)", forHTTPHeaderField: "Range")
        }
        
        return urlRequest
    }
    
    // MARK: - Network Stream Operation Queue
    
    private func addStreamOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        networkStreamQueue.addOperation(operation)
    }
    
    private func addCompletionOperation(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.qualityOfService = .background
        operation.queuePriority = .veryLow
        if let lastOperation = networkStreamQueue.operations.last {
            operation.addDependency(lastOperation)
        }
        networkStreamQueue.addOperation(operation)
    }
    
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String : String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        delegate?.metadataReceived(data: data)
    }
}
