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
    
    /// Closes the underlying stream
    func close()
    
    /// Suspends the underlying stream
    func suspend()
    
    // Resumes the underlying stream
    func resume()
    
    /// Seeks the stream at the specified offset
    func seek(at offset: Int)
    
    /// The file type, eg `mp3`, `aac`
    var audioFileHint: AudioFileTypeID { get }
}

protocol AudioStreamSource: CoreAudioStreamSource {
    
    /// The `DispatchQueue` network object will receive data
    var underlyingQueue: DispatchQueue { get }
    
    /// A `MetadataStreamSource` object that handles the metadata parsing
    var metadataStreamProccessor: MetadataStreamSource { get }
    
}
