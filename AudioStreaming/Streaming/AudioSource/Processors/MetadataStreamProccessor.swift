//
//  Created by Dimitrios Chatzieleftheriou on 29/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

protocol MetadataStreamSourceDelegate {
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
    
}

final class MetadataStreamProccessor: MetadataStreamSource {
    
    var delegate: MetadataStreamSourceDelegate?
    
    var canProccessMetadata: Bool {
        return metadataStep > 0
    }
    
    /// An `Int` read from http header value of `Icy-metaint` header
    private var metadataStep = 0
    
    /// Temporary bytes to hold the metadata from the stream buffer
    private var tempBytes: UnsafeMutablePointer<UInt8>?
    
    /// The `Data` to write from the `tempBytes` buffer
    private var data: Data?
    
    private var dataBytesRead = 0
    private var dataOffset = 0
    private var dataLength = 0
    
    private let parser: AnyParser<Data?, MetadataOutput>
    
    init(parser: AnyParser<Data?, MetadataOutput>) {
        self.parser = parser
    }

    func metadataAvailable(step: Int) {
        metadataStep = step
        dataOffset = step
    }
    
    // MARK: Proccess Metadata
    
    /**
     Metadata from Shoutcast/Icecast servers are included in the audio stream.
     There's a header value which you get on the HTTP headers *Icy-metaint* this value is the audio bytes
     ```
     =========================================
     [ audio data ][b][metadata][ audio data ]
     =========================================
     ```
     Source: https://web.archive.org/web/20190521203350/https://www.smackfu.com/stuff/programming/shoutcast.html
    */
    func proccessFromRead(into buffer: UnsafeMutablePointer<UInt8>,
                          size: Int,
                          using stream: InputStream) -> Int {
        var read: Int
        if dataOffset > 0 {
            // read the audio data
            read = stream.read(buffer, maxLength: min(dataOffset, size))
            if read > 0 {
                dataOffset -= read
            }
        } else
        {
            if dataLength == 0 {
                let metadataLengthByte = UnsafeMutablePointer<UInt8>.uint8pointer(of: 1)
                defer { metadataLengthByte.deallocate() }
                read = stream.read(metadataLengthByte, maxLength: 1)
                
                if read > 0 {
                    // get the metadata length
                    dataLength = Int(metadataLengthByte.pointee) * 16
                    if dataLength > 0 {
                        data = Data(count: dataLength)
                        tempBytes = UnsafeMutablePointer<UInt8>.uint8pointer(of: dataLength)
                        dataBytesRead = 0
                    } else {
                        dataOffset = metadataStep
                        data = nil
                        tempBytes?.deallocate()
                        tempBytes = nil
                        dataLength = 0
                    }
                    read = 0
                }
            } else {
                guard let tempBytes = tempBytes else { return 0 }
                
                read = stream.read(tempBytes + dataBytesRead,
                                   maxLength: dataLength - dataBytesRead)
                
                if read > 0 {
                    data?.append(tempBytes, count: read)
                    dataBytesRead += read
                    
                    if dataBytesRead == dataLength {
                        let processedMetadata = parser.parse(input: data)
                        delegate?.didReceiveMetadata(metadata: processedMetadata)
                        
                        // reset
                        data = nil
                        dataOffset = metadataStep
                        dataLength = 0
                        dataBytesRead = 0
                        self.tempBytes?.deallocate()
                        self.tempBytes = nil
                    }
                    
                    read = 0
                }
            }
        }
        return read
    }
}
