//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AudioToolbox

public class RemoteAudioSource: NSObject, AudioStreamSource {
    
    var inputStream: InputStream?
    var readBufferSize: Int = 0
    
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
         readBufferSize: Int,
         httpHeaders: [String: String]) {
        self.networking = networking
        self.metadataStreamProccessor = metadataStreamSource
        self.url = url
        self.sourceQueue = sourceQueue
        self.additionalRequestHeaders = httpHeaders
        self.httpStatusCode = 0
        self.relativePosition = 0
        self.seekOffset = 0
        self.readBufferSize = readBufferSize
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     sourceQueue: DispatchQueue,
                     readBufferSize: Int,
                     httpHeaders: [String: String]) {
        let metadataParser = MetadataParser()
        let metadataProccessor = MetadataStreamProccessor(parser: metadataParser.eraseToAnyParser())
        self.init(networking: networking,
                  metadataStreamSource: metadataProccessor,
                  url: url,
                  sourceQueue: sourceQueue,
                  readBufferSize: readBufferSize,
                  httpHeaders: httpHeaders)
    }
    
    convenience init(networking: NetworkingClient,
                     url: URL,
                     sourceQueue: DispatchQueue,
                     readBufferSize: Int) {
        self.init(networking: networking,
                  url: url,
                  sourceQueue: sourceQueue,
                  readBufferSize: readBufferSize,
                  httpHeaders: [:])
    }
    
    func setup() {
        guard let stream = inputStream else {
            return
        }
        stream.delegate = self
        stream.set(on: sourceQueue)
    }
    
    func removeFromQueue() {
        guard let stream = inputStream else { return }
        stream.delegate = nil
        stream.unsetFromQueue()
    }
    
    func close() {
        inputStream?.close()
        inputStream = nil
        streamRequest?.cancel()
        if let streamTask = streamRequest {
            networking.remove(task: streamTask)
        }
        streamRequest = nil
    }
    
    func seek(at offset: Int) {
        dispatchPrecondition(condition: .onQueue(sourceQueue))
        
        self.close()
        
        relativePosition = 0
        seekOffset = offset
        
        if let supportsSeek = self.parsedHeaderOutput?.supportsSeek,
           !supportsSeek && offset != relativePosition  {
            return
        }
        
        self.performOpen(seek: offset)
    }
    
    func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        return self.performRead(into: buffer, size: size)
    }
    
    
    // MARK: Private
    
    private func performRead(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        guard size != 0 else { return 0 }
        guard let stream = inputStream else { return 0 }
        
        var read: Int = 0
        // Metadata parsing
        if metadataStreamProccessor.canProccessMetadata {
            read = metadataStreamProccessor.proccessFromRead(into: buffer, size: size, using: stream)
        } else {
            read = stream.read(buffer, maxLength: size)
        }
        
        guard read > 0 else { return read }
        relativePosition += read
        
        return read
    }
    
    private func performOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)
        
        let request = networking.stream(request: urlRequest)
        streamRequest = request
        inputStream = request.asInputStream(bufferSize: readBufferSize)
        guard let inputStream = inputStream else {
            delegate?.errorOccured(source: self)
            return
        }
        
        metadataStreamProccessor.delegate = self
        inputStream.delegate = self
        inputStream.set(on: sourceQueue)
        inputStream.open()
        
    }
    
    private func performSoftSetup() {
        guard let stream = inputStream else {
            return
        }
        stream.set(on: sourceQueue)
    }
    
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

extension RemoteAudioSource: StreamDelegate {
    
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
            case .openCompleted:
                Logger.debug("input stream open completed", category: .networking)
            case .hasBytesAvailable:
                if httpStatusCode == 0 {
                    if self.parseResponseHeader(response: httpResponse) {
                        self.delegate?.dataAvailable(source: self)
                    }
                } else {
                    self.delegate?.dataAvailable(source: self)
                }
            case .endEncountered:
                self.delegate?.endOfFileOccured(source: self)
            case .errorOccurred:
                self.delegate?.errorOccured(source: self)
            default:
                break
        }
    }
    
}


extension RemoteAudioSource: MetadataStreamSourceDelegate {
    func didReceiveMetadata(metadata: Result<[String : String], MetadataParsingError>) {
        guard case let .success(data) = metadata else { return }
        self.delegate?.metadataReceived(data: data)
    }
}
