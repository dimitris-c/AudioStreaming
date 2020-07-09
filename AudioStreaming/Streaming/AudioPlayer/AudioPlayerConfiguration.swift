//
//  Created by Dimitrios Chatzieleftheriou on 09/07/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

public struct AudioPlayerConfiguration: Equatable {
    /// All pending items will be flushed when seeking a track if this is set to `true`
    let flushQueueOnSeek: Bool
    ///
    let enableVolumeMixer: Bool
    /// The size of the I/O read buffer.
    let readBufferSize: Int
    /// The size of the decompressed buffer.
    let bufferSizeInSeconds: Double
    /// Number of seconds of audio required to before playback first starts.
    /// - note: Must be larger that `bufferSizeInSeconds`
    let secondsRequiredToStartPlaying: Double
    ///
    let gracePeriodAfterSeekInSeconds: Double
    /// Number of seconds of audio required to before playback resumes after a buffer underun
    /// - note: Must be larger that `bufferSizeInSeconds`
    let secondsRequiredToStartPlayingAfterBufferUnderun: Int
    
    static public let `default` = AudioPlayerConfiguration(flushQueueOnSeek: true,
                                                           enableVolumeMixer: true,
                                                           readBufferSize: 64 * 1024,
                                                           bufferSizeInSeconds: 10,
                                                           secondsRequiredToStartPlaying: 1,
                                                           gracePeriodAfterSeekInSeconds: 0.5,
                                                           secondsRequiredToStartPlayingAfterBufferUnderun: 7)
    /// Normalize values on any zero values passed
    func normalizeValues() -> AudioPlayerConfiguration {
        let defaultValues = AudioPlayerConfiguration.default
        let readBufferSize = self.readBufferSize == 0 ? defaultValues.readBufferSize : self.readBufferSize
        let bufferSizeInSeconds = self.bufferSizeInSeconds == 0 ? defaultValues.bufferSizeInSeconds : self.bufferSizeInSeconds
        let secondsRequiredToStartPlaying = self.secondsRequiredToStartPlaying == 0 ? defaultValues.secondsRequiredToStartPlaying : self.secondsRequiredToStartPlaying
        let gracePeriodAfterSeekInSeconds = self.gracePeriodAfterSeekInSeconds == 0 ? defaultValues.gracePeriodAfterSeekInSeconds : self.gracePeriodAfterSeekInSeconds
        
        let secondsRequiredToStartPlayingAfterBufferUnderun = self.secondsRequiredToStartPlayingAfterBufferUnderun == 0 ?
            defaultValues.secondsRequiredToStartPlayingAfterBufferUnderun : self.secondsRequiredToStartPlayingAfterBufferUnderun
        
        return AudioPlayerConfiguration(flushQueueOnSeek: self.flushQueueOnSeek,
                                        enableVolumeMixer: self.enableVolumeMixer,
                                        readBufferSize: readBufferSize,
                                        bufferSizeInSeconds: bufferSizeInSeconds,
                                        secondsRequiredToStartPlaying: secondsRequiredToStartPlaying,
                                        gracePeriodAfterSeekInSeconds: gracePeriodAfterSeekInSeconds,
                                        secondsRequiredToStartPlayingAfterBufferUnderun: secondsRequiredToStartPlayingAfterBufferUnderun)
    }
}

