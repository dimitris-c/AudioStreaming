//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import Foundation

typealias CoreAudioURLBlock = (URL) -> Void

public class RemoteAudioSource: NSObject, AudioStreamSource {
    var inputStream: InputStream?

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
    internal let metadataStreamProccessor: MetadataStreamSource
    private var streamRequest: NetworkDataStream?

    private var additionalRequestHeaders: [String: String]
    private var httpStatusCode: Int

    private var httpResponse: HTTPURLResponse?
    private var parsedHeaderOutput: HTTPHeaderParserOutput?
    private var relativePosition: Int
    private var seekOffset: Int

    internal var dispatchQueue: DispatchQueue?

    init(networking: NetworkingClient,
         metadataStreamSource: MetadataStreamSource,
         url: URL,
         httpHeaders: [String: String])
    {
        self.networking = networking
        metadataStreamProccessor = metadataStreamSource
        self.url = url
        additionalRequestHeaders = httpHeaders
        httpStatusCode = 0
        relativePosition = 0
        seekOffset = 0
    }

    convenience init(networking: NetworkingClient, url: URL, httpHeaders: [String: String]) {
        let metadataParser = MetadataParser()
        let metadataProccessor = MetadataStreamProccessor(parser: metadataParser.eraseToAnyParser())
        self.init(networking: networking,
                  metadataStreamSource: metadataProccessor,
                  url: url,
                  httpHeaders: httpHeaders)
    }

    convenience init(networking: NetworkingClient, url: URL) {
        self.init(networking: networking,
                  url: url,
                  httpHeaders: [:])
    }

    func setup(for queue: DispatchQueue) {
        dispatchQueue = queue

        guard let stream = inputStream else {
            return
        }

        stream.delegate = self
        stream.set(onQueue: queue)

        return
    }

    func removeFromQueue() {
        guard let stream = inputStream else { return }
        stream.delegate = nil
        stream.unsetFromQueue()
    }

    func close() {
        if inputStream != nil {
            if dispatchQueue != nil {
                removeFromQueue()
            }
            inputStream?.close()
            inputStream = nil
        }
    }

    func seek(at offset: Int) {
        guard let queue = dispatchQueue else {
            return
        }
        dispatchPrecondition(condition: .onQueue(queue))

        close()

        relativePosition = 0
        seekOffset = offset

        if let supportsSeek = parsedHeaderOutput?.supportsSeek,
           !supportsSeek, offset != relativePosition
        {
            return
        }

        performOpen(seek: seekOffset)
    }

    func audioFileHint() -> AudioFileTypeID {
        return audioFileType(fileExtension: url.pathExtension)
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        return performRead(into: buffer, size: size)
    }

    // MARK: Private

    private func performRead(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int {
        guard size != 0 else { return 0 }
        guard let stream = inputStream else { return 0 }

        var read: Int = 0
        // Metadata parsing
//        if metadataStreamProccessor.canProccessMetadata {
//            read = metadataStreamProccessor.proccessFromRead(into: buffer, size: size, using: stream) { [weak self] position in
//                self?.relativePosition += position
//            }
//        } else {
        read = stream.read(buffer, maxLength: size)
//        }

        guard read > 0 else { return read }
        relativePosition += read

        return read
    }

    private func performOpen(seek seekOffset: Int) {
        let urlRequest = buildUrlRequest(with: url, seekIfNeeded: seekOffset)

        let streamRequest = networking.stream(request: urlRequest)
            .responseStream(on: .global(qos: .default)) { [weak self] event in
                switch event {
                case let .stream(result):
                    switch result {
                    case let .success(response):
                        self?.httpResponse = response.response
                    default:
                        break
                    }
                case let .complete(completion):
                    print(completion)
                }
            }
        self.streamRequest = streamRequest
        inputStream = streamRequest.asInputStream()

        guard let inputStream = inputStream else {
            errorOccured()
            return
        }

        inputStream.setProperty(StreamNetworkServiceTypeValue.background, forKey: .networkServiceType)

        if let scheme = url.scheme, scheme == "https" {
            inputStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            let sslSettings: [String: Any] = [kCFStreamSSLValidatesCertificateChain as String: false]
            inputStream.setProperty(sslSettings, forKey: kCFStreamPropertySSLSettings as Stream.PropertyKey)
        }

        performSoftSetup()
        httpStatusCode = 0

        inputStream.open()
    }

    private func parseHeader(response: HTTPURLResponse?) -> Bool {
        guard let response = response else { return false }
        httpStatusCode = response.statusCode
        // parse the header response
        let parser = HTTPHeaderParser()
        parsedHeaderOutput = parser.parse(input: response)
        // check to see if we have metadata to proccess
        if let metadataStep = parsedHeaderOutput?.metadataStep {
            metadataStreamProccessor.metadataAvailable(step: metadataStep)
        }
        // check for error
        if httpStatusCode == 416 { // range not satisfied error
            if length >= 0 { seekOffset = length }
            endOfFileOccurred()
            return false
        } else if httpStatusCode >= 300 {
            errorOccured()
            return false
        }
        return true
    }

    private func performSoftSetup() {
        guard let queue = dispatchQueue, let inputStream = inputStream else { return }
        inputStream.delegate = self
        inputStream.set(onQueue: queue)
    }

    private func buildUrlRequest(with _: URL, seekIfNeeded seekOffset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 30
        urlRequest.networkServiceType = .avStreaming

        for header in additionalRequestHeaders {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.key)
        }
        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("1", forHTTPHeaderField: "Icy-Metadata")

        if let supportsSeek = parsedHeaderOutput?.supportsSeek, supportsSeek, seekOffset > 0 {
            urlRequest.addValue("bytes=\(seekOffset)", forHTTPHeaderField: "Range")
        }

        return urlRequest
    }
}

// MARK: StreamEventsSource

extension RemoteAudioSource: StreamEventsSource {
    func openCompleted() {
        print("open completed")
    }

    func dataAvailable() {
        guard inputStream != nil else { return }
        if httpStatusCode == 0 {
            guard parseHeader(response: httpResponse) else { return }
            if hasBytesAvailable {
                delegate?.dataAvailable(source: self)
            }
        } else {
            delegate?.dataAvailable(source: self)
        }
    }

    func endOfFileOccurred() {
        delegate?.endOfFileOccured(source: self)
    }

    func errorOccured() {
        delegate?.errorOccured(source: self)
    }
}

// MARK: StreamDelegate

extension RemoteAudioSource: StreamDelegate {
    public func stream(_: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            openCompleted()
        case .hasBytesAvailable:
            dataAvailable()
        case .endEncountered:
            endOfFileOccurred()
        case .errorOccurred:
            errorOccured()
        default: break
        }
    }
}
