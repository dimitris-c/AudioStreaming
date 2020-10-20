//
//  Created by Dimitrios Chatzieleftheriou on 02/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

// MARK: Internal State
extension AudioPlayer {
    internal struct InternalState: OptionSet {
        var rawValue: Int
        
        static let initial = InternalState([])
        static let running = InternalState(rawValue: 1)
        static let playing = InternalState(rawValue: 1 << 1 | InternalState.running.rawValue)
        static let rebuffering = InternalState(rawValue: 1 << 2 | InternalState.running.rawValue)
        static let startingThread = InternalState(rawValue: 1 << 3 | InternalState.running.rawValue)
        static let waitingForData = InternalState(rawValue: 1 << 4 | InternalState.running.rawValue)
        static let waitingForDataAfterSeek = InternalState(rawValue: 1 << 5 | InternalState.running.rawValue)
        static let paused = InternalState(rawValue: 1 << 6 | InternalState.running.rawValue)
        static let stopped = InternalState(rawValue: 1 << 9)
        static let pendingNext = InternalState(rawValue: 1 << 10)
        static let disposed = InternalState(rawValue: 1 << 30)
        static let error = InternalState(rawValue: 1 << 31)
        
        static let isPlaying: InternalState =
            [.running, .startingThread, .playing, .waitingForDataAfterSeek]
        static let isBuffering: InternalState =
            [.pendingNext, .rebuffering, .waitingForData]
        
    }
}

func playerStateAndStopReason(for internalState: AudioPlayer.InternalState) -> (state: AudioPlayerState, stopReason: AudioPlayerStopReason) {
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

public enum AudioPlayerError: LocalizedError, Equatable {
    case streamParseBytesFailure
    case audioSystemError(AudioSystemError)
    case codecError
    case dataNotFound
    case networkError(NetworkError)
    case other
    
    public var errorDescription: String? {
        switch self {
            case .streamParseBytesFailure:
                return "Couldn't parse the bytes from the stream"
            case .audioSystemError(let error):
                return error.errorDescription
            case .codecError:
                return "Codec error while parsing data packets"
            case .dataNotFound:
                return "No data supplied from network stream"
            case .networkError(let error):
                return error.localizedDescription
            case .other:
                return "Audio Player error"
        }
    }
}

public enum AudioSystemError: LocalizedError, Equatable {
    case engineFailure
    case playerNotFound
    case playerStartError
    case fileStreamError
    
    public var errorDescription: String? {
        switch self {
            case .engineFailure: return "Audio engine couldn't start"
            case .playerNotFound: return "Player not found"
            case .playerStartError: return "Player couldn't start"
            case .fileStreamError: return "Audio file stream couldn't start"
        }
    }
}
