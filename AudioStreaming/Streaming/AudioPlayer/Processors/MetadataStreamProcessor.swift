//
//  Created by Dimitrios Chatzieleftheriou on 29/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

protocol MetadataStreamSourceDelegate: class {
    func didReceiveMetadata(metadata: Result<[String: String], MetadataParsingError>)
}

protocol MetadataStreamSource {
    
    var delegate: MetadataStreamSourceDelegate? { get set }
    
    /// Returns `true` when the stream header has indicated that we can proccess metadata, otherwise `false`.
    var canProccessMetadata: Bool { get }
    
    /// Assigns the metadata step of the metadata
    func metadataAvailable(step: Int)
    
    /// Proccess the received data and extract the metadata if any, returns audio data only.
    /// - parameter data: A `Data` object for parsing any metadata
    /// - returns: The extracted audio `Data`
    func proccessMetadata(data: Data) -> Data
}

final class MetadataStreamProcessor: MetadataStreamSource {
    func proccessFromRead(into buffer: UnsafeMutablePointer<UInt8>, size: Int, using stream: InputStream) -> Int {
        return 0
    }
    
    
    weak var delegate: MetadataStreamSourceDelegate?
    
    var canProccessMetadata: Bool {
        return metadataStep > 0
    }
    
    /// An `Int` read from http header value of `Icy-metaint` header
    private var metadataStep = 0
    
    /// Temporary bytes to hold the metadata from the stream buffer
    private var tempBytes: UnsafeMutablePointer<UInt8>?
    
    /// The `Data` to write the metadata
    private var metadataData = Data()
    
    private var dataBytesRead = 0
    private var metadataOffset = 0
    private var metadataLength: Int = 0
    
    private let parser: AnyParser<Data?, MetadataOutput>
    
    init(parser: AnyParser<Data?, MetadataOutput>) {
        self.parser = parser
    }

    func metadataAvailable(step: Int) {
        metadataStep = step
        metadataOffset = step
    }
    
    // MARK: Proccess Metadata
    
    /**
     Metadata from Shoutcast/Icecast servers are included in the audio stream.
     There's a header value which you get on the HTTP headers *Icy-metaint* this value is the audio bytes between
     the metadata.
     ```
     =========================================
     [ audio data ][b][metadata][ audio data ]
     =========================================
     ```
     Source: https://web.archive.org/web/20190521203350/https://www.smackfu.com/stuff/programming/shoutcast.html
    */
    @inline(__always)
    func proccessMetadata(data: Data) -> Data {
        var audioData = Data()
        let _data = data as NSData
        _data.enumerateBytes { (bytes, range, _) in
            var bytesRead = 0

            while bytesRead < range.length {
                let remainingBytes = range.length - bytesRead
                let pointer = bytes + bytesRead
                if metadataLength > 0 {
                    let remainingMetaBytes = metadataLength - metadataData.count
                    let bytesToAppend = min(remainingMetaBytes, remainingBytes)
                    metadataData.append(pointer.assumingMemoryBound(to: UInt8.self), count: bytesToAppend)

                    if metadataData.count == metadataLength {
                        let processedMetadata = parser.parse(input: metadataData)
                        delegate?.didReceiveMetadata(metadata: processedMetadata)

                        metadataData.count = 0
                        metadataLength = 0
                        dataBytesRead = 0
                    }

                    bytesRead += bytesToAppend
                } else if dataBytesRead == metadataStep {
                    let metaLength = Int(pointer.assumingMemoryBound(to: UInt8.self).pointee) * 16
                    if metaLength > 0 {
                        metadataLength = Int(metaLength)
                    } else {
                        dataBytesRead = 0
                    }
                    bytesRead += 1
                } else {
                    let audioBytesToRead = min(metadataStep - dataBytesRead, remainingBytes)
                    audioData.append(pointer.assumingMemoryBound(to: UInt8.self), count: audioBytesToRead)

                    dataBytesRead += audioBytesToRead
                    bytesRead += audioBytesToRead
                }
            }
        }

        return audioData
    }
    
}
