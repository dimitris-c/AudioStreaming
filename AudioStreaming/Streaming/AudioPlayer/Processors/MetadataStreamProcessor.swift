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
    
    func metadataAvailable(step: Int)
    
    /// Proccess the received `buffer` of `size` on the given `InputStream` for the stream metadata
    /// - parameter buffer: `UnsafeMutablePointer<UInt8>`
    /// - parameter size: `Int`
    /// - parameter stream: InputStream to read the buffer
    /// - parameter updatePosition: A block that updates the relative position, if needed
    /// - returns: The read buffer
    func proccessFromRead(into buffer: UnsafeMutablePointer<UInt8>,
                          size: Int,
                          using stream: InputStream) -> Int
    
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
    
    /// The `Data` to write from the `tempBytes` buffer
    /// The `Data` to write from the `tempBytes` buffer
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
//    @inline(__always)
//    func proccessFromRead(into buffer: UnsafeMutablePointer<UInt8>,
//                          size: Int,
//                          using stream: InputStream) -> Int {
//        var read: Int
//        if dataOffset > 0 {
//            // read the audio data
//            read = stream.read(buffer, maxLength: min(dataOffset, size))
//            dataOffset -= max(0, read)
//        } else {
//            if dataLength == 0 {
//                let metadataLengthByte = UnsafeMutablePointer<UInt8>.uint8pointer(of: 1)
//                defer { metadataLengthByte.deallocate() }
//                read = stream.read(metadataLengthByte, maxLength: 1)
//
//                if read > 0 {
//                    // get the metadata length
//                    dataLength = Int(metadataLengthByte.pointee) * 16
//                    if dataLength > 0 {
//                        metaData = Data(count: dataLength)
//                        tempBytes = UnsafeMutablePointer<UInt8>.uint8pointer(of: dataLength)
//                        dataBytesRead = 0
//                    } else {
//                        metaData = nil
//                        dataOffset = metadataStep
//                        dataLength = 0
//                        tempBytes?.deallocate()
//                        tempBytes = nil
//                    }
//                    read = 0
//                }
//            } else {
//                guard let tempBytes = tempBytes else { return 0 }
//
//                let bytes = tempBytes + dataBytesRead
//                let length = dataLength - dataBytesRead
//                read = stream.read(bytes, maxLength: length)
//
//                if read > 0 {
//                    metaData?.append(tempBytes, count: read)
//                    dataBytesRead += read
//
//                    if dataBytesRead == dataLength {
//                        let processedMetadata = parser.parse(input: metaData)
//                        delegate?.didReceiveMetadata(metadata: processedMetadata)
//
//                        self.reset()
//                    }
//
//                    read = 0
//                }
//            }
//        }
//        return read
//    }
//
//    private func reset() {
//        metaData = nil
//        dataOffset = metadataStep
//        dataLength = 0
//        dataBytesRead = 0
//        tempBytes?.deallocate()
//        tempBytes = nil
//    }
}
