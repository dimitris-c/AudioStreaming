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
    internal var metadataStreamProccessor: MetadataStreamSource
    private var streamRequest: NetworkDataStream?
    
    private var additionalRequestHeaders: [String: String]
    private var httpStatusCode: Int
    
    private var httpResponse: HTTPURLResponse? {
        streamRequest?.urlResponse
    }
    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int
    
    internal var audioFileHint: AudioFileTypeID {
        if let output = parsedHeaderOutput {
            return output.typeId
        }
        return audioFileType(fileExtension: self.url.pathExtension)
    }
    
    let sourceQueue: DispatchQueue
    
    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         url: URL,
         sourceQueue: DispatchQueue,
         httpHeaders: [String: String]) {
        self.networking = networking
        self.metadataStreamProccessor = metadataStreamSource
        self.url = url
        self.sourceQueue = sourceQueue
        self.additionalRequestHeaders = httpHeaders
        self.httpStatusCode = 0
        self.relativePosition = 0
        self.seekOffset = 0
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     sourceQueue: DispatchQueue,
                     httpHeaders: [String: String]) {
        let metadataParser = MetadataParser()
        let metadataProccessor = MetadataStreamProcessor(parser: metadataParser.eraseToAnyParser())
        self.init(networking: networking,
                  metadataStreamSource: metadataProccessor,
                  url: url,
                  sourceQueue: sourceQueue,
                  httpHeaders: httpHeaders)
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     sourceQueue: DispatchQueue) {
        self.init(networking: networking,
                  url: url,
                  sourceQueue: sourceQueue,
                  httpHeaders: [:])
    }
    
    func close() {
        streamRequest?.cancel()
        if let streamTask = streamRequest {
            networking.remove(task: streamTask)
        }
        streamRequest = nil
    }
    
    func seek(at offset: Int) {
        close()
        
        relativePosition = 0
        seekOffset = offset
        
        if let supportsSeek = self.parsedHeaderOutput?.supportsSeek,
           !supportsSeek && offset != relativePosition  {
            return
        }
        
        performOpen(seek: offset)
    }
    
    // MARK: Private
    
    private func performOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        
        streamRequest = networking.stream(request: urlRequest)
            .responseStream(on: sourceQueue) { [weak self] event in
                guard let self = self else { return }
                self.handleResponse(event: event)
        }
        streamRequest?.resume()
        metadataStreamProccessor.delegate = self
    }
    
    private func handleResponse(event: NetworkDataStream.StreamEvent) {
        switch event {
            case .complete(let _):
                self.delegate?.endOfFileOccured(source: self)
            case .stream(let event):
                self.handleStreamEvent(event: event)
        }
    }
    
    private func handleStreamEvent(event: NetworkDataStream.StreamResult) {
        switch event {
            case .success(let responseValue):
                if let response = responseValue.response, httpStatusCode == 0 {
                    self.parseResponseHeader(response: response)
                }
                if let data = responseValue.data {
                    if metadataStreamProccessor.canProccessMetadata {
                        let extractedAudioData = metadataStreamProccessor.proccessMetadata(data: data)
                        self.delegate?.dataAvailable(source: self, data: extractedAudioData)
                    } else {
                        self.delegate?.dataAvailable(source: self, data: data)
                    }
                    relativePosition += data.count
                }
            case .failure(let error):
                print(error)
                self.delegate?.errorOccured(source: self)
                break
        }
    }
    
    @discardableResult
    private func parseResponseHeader(response: HTTPURLResponse?) -> Bool {
        guard let response = response else { return false }
        guard httpStatusCode == 0 else { return false }
        // TODO: Parse Icy header
        httpStatusCode = response.statusCode
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
            return false
        }
        else if httpStatusCode >= 300 {
            delegate?.errorOccured(source: self)
            return false
        }
        
        return true
    }
    
    private func buildUrlRequest(with url: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: self.url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        
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
    
}

extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String : String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        self.delegate?.metadataReceived(data: data)
    }
}
