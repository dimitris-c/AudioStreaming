//
//  Created by Dimitrios Chatzieleftheriou on 02/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

// MARK: Internal State
internal struct PlayerInternalState: OptionSet {
    var rawValue: Int
    
    static let initial = PlayerInternalState([])
    static let running = PlayerInternalState(rawValue: 1)
    static let playing = PlayerInternalState(rawValue: 1 << 1 | PlayerInternalState.running.rawValue)
    static let rebuffering = PlayerInternalState(rawValue: 1 << 2 | PlayerInternalState.running.rawValue)
    static let startingThread = PlayerInternalState(rawValue: 1 << 3 | PlayerInternalState.running.rawValue)
    static let waitingForData = PlayerInternalState(rawValue: 1 << 4 | PlayerInternalState.running.rawValue)
    static let waitingForDataAfterSeek = PlayerInternalState(rawValue: 1 << 5 | PlayerInternalState.running.rawValue)
    static let paused = PlayerInternalState(rawValue: 1 << 6 | PlayerInternalState.running.rawValue)
    static let stopped = PlayerInternalState(rawValue: 1 << 9)
    static let pendingNext = PlayerInternalState(rawValue: 1 << 10)
    static let disposed = PlayerInternalState(rawValue: 1 << 30)
    static let error = PlayerInternalState(rawValue: 1 << 31)
    
    static let isPlaying: PlayerInternalState =
        [.running, .startingThread, .playing, .waitingForDataAfterSeek]
    static let isBuffering: PlayerInternalState =
        [.pendingNext, .rebuffering, .waitingForData]
    
}

func playerStateAndStopReason(for internalState: PlayerInternalState) -> (state: AudioPlayerState, stopReason: AudioPlayerStopReason) {
    var playerNewState: AudioPlayerState
    var stopReason: AudioPlayerStopReason = .none
    
    switch internalState {
    case .initial:
        playerNewState = .ready
        stopReason = .none
    case .running, .startingThread, .playing, .waitingForDataAfterSeek:
        playerNewState = .playing
        stopReason = .none
    case .pendingNext, .rebuffering, .waitingForData:
        playerNewState = .bufferring
        stopReason = .none
    case .stopped:
        playerNewState = .stopped
        stopReason = .userAction
    case .paused:
        playerNewState = .paused
        stopReason = .none
    case .disposed:
        playerNewState = .disposed
        stopReason = .userAction
    case .error:
        playerNewState = .error
        stopReason = .error
    default:
        playerNewState = .ready
        stopReason = .none
    }
    
    return (playerNewState, stopReason)
}

// MARK: Public States
public enum AudioPlayerState: Equatable {
    case ready
    case running
    case playing
    case bufferring
    case paused
    case stopped
    case error
    case disposed
}

public enum AudioPlayerStopReason: Equatable {
    case none
    case eof
    case userAction
    case error
    case disposed
}

public enum AudioPlayerErrorCode: Error, Equatable {
    case none
    case streamParseBytesFailure
    case audioSystemError
    case codecError
    case dataNotFound
    case other
}

public struct AudioPlayerConfiguration {
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
    let secondsRequiredToStartPlaying: Int
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
}

