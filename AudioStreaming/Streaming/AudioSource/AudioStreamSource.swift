//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AudioToolbox

protocol AudioStreamSourceDelegate: class {
    /// Indicates that there's data available
    func dataAvailable(source: AudioStreamSource, data: Data)
    /// Indicates an error occurred
    func errorOccured(source: AudioStreamSource)
    /// Indicates end of file has occurred
    func endOfFileOccured(source: AudioStreamSource)
    /// Indicates metadata read from stream
    func metadataReceived(data: [String: String])
}

protocol CoreAudioStreamSource: class {
    /// An `Int` that represents the position of the audio
    var position: Int { get }
    /// The length of the audio in bytes
    var length: Int { get }
    
    /// An `AudioStreamSourceDelegate` object to listen for events from the source
    var delegate: AudioStreamSourceDelegate? { get set }
    
    /// Reads up to a given number of bytes into a given buffer.
    /// - parameter buffer: A mutable pointer of `UInt8` to hold the current buffer of stream
    /// - parameter size: The maximum length for the buffer to read
    /// - returns: As per `InputStream` documentation
    ///     - A positive number indicates the number of bytes read.
    ///     - 0 indicates that the end of the buffer was reached.
    ///     - -1 means that the operation failed; more information about the error can be obtained with streamError.
    func read(into buffer: UnsafeMutablePointer<UInt8>, size: Int) -> Int

    func setup()
    
    func removeFromQueue()
    
    /// Closes the underlying stream
    func close()
    
    /// Seeks the stream at the specified offset
    func seek(at offset: Int)
    
    /// The file type, eg `mp3`, `aac`
    var audioFileHint: AudioFileTypeID { get }
}

protocol AudioStreamSource: CoreAudioStreamSource {
    
    var inputStream: InputStream? { get }
    
    /// The `DispatchQueue` network object will receive data
    var sourceQueue: DispatchQueue { get }
    
    /// A `MetadataStreamSource` object that handles the metadata parsing
    var metadataStreamProccessor: MetadataStreamSource { get }
    
    /// Returns `true` if the source has bytes available to be processed
    var hasBytesAvailable: Bool { get }
    
    /// The status of the stream
    var streamStatus: InputStream.Status { get }
    
}

extension AudioStreamSource {
    var hasBytesAvailable: Bool {
        guard let stream = inputStream else { return false }
        return stream.hasBytesAvailable
    }
    
    var streamStatus: InputStream.Status {
        guard let stream = inputStream else { return .error }
        return stream.streamStatus
    }
}
