//
//  Created by Dimitrios Chatzieleftheriou on 27/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox
import Foundation

public enum AudioContentType: Equatable, Sendable {
    /// Infers live broadcasts from response metadata, defaulting ambiguous streams to on-demand.
    case automatic
    /// Finite content whose buffered data is preserved while playback is paused.
    case onDemand
    /// A continuous broadcast that reconnects at the live edge after a pause.
    case live
}

public protocol AudioStreamSourceDelegate: AnyObject {
    /// Indicates that there's data available
    func dataAvailable(source: CoreAudioStreamSource, data: Data)
    /// Indicates an error occurred
    func errorOccurred(source: CoreAudioStreamSource, error: Error)
    /// Indicates end of file has occurred
    func endOfFileOccurred(source: CoreAudioStreamSource)
    /// Indicates metadata read from stream
    func metadataReceived(data: [String: String])
}

public protocol CoreAudioStreamSource: AnyObject {
    /// Controls how pausing affects the source.
    var contentType: AudioContentType { get }

    /// An `Int` that represents the position of the audio
    var position: Int { get }
    /// The length of the audio in bytes
    var length: Int { get }

    /// An `AudioStreamSourceDelegate` object to listen for events from the source
    var delegate: AudioStreamSourceDelegate? { get set }

    /// Closes the underlying stream
    func close()

    /// Suspends the underlying stream
    func suspend()

    /// Resumes the underlying stream
    func resume()

    /// Seeks the stream at the specified offset
    func seek(at offset: Int)

    /// The file type, eg `mp3`, `aac`
    var audioFileHint: AudioFileTypeID { get }

    /// The `DispatchQueue` network object will receive data
    var underlyingQueue: DispatchQueue { get }
}

public extension CoreAudioStreamSource {
    var contentType: AudioContentType { .onDemand }
}

protocol AudioStreamSource: CoreAudioStreamSource {
    /// A `MetadataStreamSource` object that handles the metadata parsing
    var metadataStreamProcessor: MetadataStreamSource { get }
}
