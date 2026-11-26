//
//  Created by Dimitrios Chatzieleftheriou on 09/07/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import OSLog

public struct AudioPlayerConfiguration: Equatable {
    /// All pending items will be flushed when seeking a track if this is set to `true`
    let flushQueueOnSeek: Bool
    /// The size of the decompressed buffer.
    let bufferSizeInSeconds: Double
    /// Number of seconds of audio required to before playback first starts.
    /// - note: Must be larger that `bufferSizeInSeconds`
    let secondsRequiredToStartPlaying: Double
    /// Number of seconds of audio required after seek occurs.
    let gracePeriodAfterSeekInSeconds: Double
    /// Number of seconds of audio required to before playback resumes after a buffer underrun
    /// - note: Must be larger that `bufferSizeInSeconds`
    let secondsRequiredToStartPlayingAfterBufferUnderrun: Int

    /// The sample rate, in hertz, of the player's output format.
    ///
    /// Decoded audio is converted to this rate before it reaches the engine, so it should match
    /// the rate the output hardware is actually running at — on iOS,
    /// `AVAudioSession.sharedInstance().sampleRate`. Leaving it at the 44100 default on hardware
    /// running at another rate makes the system resample a second time: a 48 kHz source is
    /// converted down to 44100 here and back up to 48000 by the output unit.
    let outputSampleRate: Double

    /// Enables the internal logs
    let enableLogs: Bool

    public static let `default` = AudioPlayerConfiguration(flushQueueOnSeek: false,
                                                           bufferSizeInSeconds: 10,
                                                           secondsRequiredToStartPlaying: 1,
                                                           gracePeriodAfterSeekInSeconds: 0.5,
                                                           secondsRequiredToStartPlayingAfterBufferUnderrun: 7,
                                                           outputSampleRate: 44100,
                                                           enableLogs: false)
    /// Initializes the configuration for the `AudioPlayer`
    ///
    /// Parameters are pre set for convenience
    ///
    /// - parameter flushQueueOnSeek: All pending items will be flushed when seeking a track if this is set to `true`
    /// - parameter bufferSizeInSeconds: The size of the decompressed buffer.
    /// - parameter secondsRequiredToStartPlaying: Number of seconds of audio required to before playback first starts.
    /// - parameter gracePeriodAfterSeekInSeconds: Number of seconds of audio required after seek occurs.
    /// - parameter secondsRequiredToStartPlayingAfterBufferUnderrun: Number of seconds of audio required to before playback resumes after a buffer underrun
    /// - parameter outputSampleRate: Sample rate, in hertz, of the player's output format
    /// - parameter enableLogs: Enables the internal logs
    ///
    public init(flushQueueOnSeek: Bool = true,
                bufferSizeInSeconds: Double = 10,
                secondsRequiredToStartPlaying: Double = 1,
                gracePeriodAfterSeekInSeconds: Double = 0.5,
                secondsRequiredToStartPlayingAfterBufferUnderrun: Int = 1,
                outputSampleRate: Double = 44100,
                enableLogs: Bool = true)
    {
        self.flushQueueOnSeek = flushQueueOnSeek
        self.bufferSizeInSeconds = bufferSizeInSeconds
        self.secondsRequiredToStartPlaying = secondsRequiredToStartPlaying
        self.gracePeriodAfterSeekInSeconds = gracePeriodAfterSeekInSeconds
        self.secondsRequiredToStartPlayingAfterBufferUnderrun = secondsRequiredToStartPlayingAfterBufferUnderrun
        self.outputSampleRate = outputSampleRate
        self.enableLogs = enableLogs
        Logger.isEnabled = enableLogs
    }

    /// Normalize values on any zero values passed
    func normalizeValues() -> AudioPlayerConfiguration {
        let defaults = AudioPlayerConfiguration.default

        let bufferSizeInSeconds = self.bufferSizeInSeconds == 0
            ? defaults.bufferSizeInSeconds
            : self.bufferSizeInSeconds

        let secondsRequiredToStartPlaying = self.secondsRequiredToStartPlaying == 0
            ? defaults.secondsRequiredToStartPlaying
            : self.secondsRequiredToStartPlaying

        let gracePeriodAfterSeekInSeconds = self.gracePeriodAfterSeekInSeconds == 0
            ? defaults.gracePeriodAfterSeekInSeconds
            : self.gracePeriodAfterSeekInSeconds

        let secondsRequiredToStartPlayingAfterBufferUnderrun = self.secondsRequiredToStartPlayingAfterBufferUnderrun == 0
            ? defaults.secondsRequiredToStartPlayingAfterBufferUnderrun
            : self.secondsRequiredToStartPlayingAfterBufferUnderrun

        // A non-positive rate would make `AVAudioFormat` fail to initialise.
        let outputSampleRate = self.outputSampleRate > 0
            ? self.outputSampleRate
            : defaults.outputSampleRate

        return AudioPlayerConfiguration(flushQueueOnSeek: flushQueueOnSeek,
                                        bufferSizeInSeconds: bufferSizeInSeconds,
                                        secondsRequiredToStartPlaying: secondsRequiredToStartPlaying,
                                        gracePeriodAfterSeekInSeconds: gracePeriodAfterSeekInSeconds,
                                        secondsRequiredToStartPlayingAfterBufferUnderrun: secondsRequiredToStartPlayingAfterBufferUnderrun,
                                        outputSampleRate: outputSampleRate,
                                        enableLogs: enableLogs)
    }
}
