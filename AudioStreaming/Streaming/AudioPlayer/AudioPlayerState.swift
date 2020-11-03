//
//  Created by Dimitrios Chatzieleftheriou on 02/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

// MARK: Internal State

extension AudioPlayer {
    struct InternalState: OptionSet {
        var rawValue: Int

        static let initial = InternalState([])
        static let running = InternalState(rawValue: 1)
        static let playing = InternalState(rawValue: 1 << 1 | InternalState.running.rawValue)
        static let rebuffering = InternalState(rawValue: 1 << 2 | InternalState.running.rawValue)
        static let waitingForData = InternalState(rawValue: 1 << 3 | InternalState.running.rawValue)
        static let waitingForDataAfterSeek = InternalState(rawValue: 1 << 4 | InternalState.running.rawValue)
        static let paused = InternalState(rawValue: 1 << 5 | InternalState.running.rawValue)
        static let stopped = InternalState(rawValue: 1 << 9)
        static let pendingNext = InternalState(rawValue: 1 << 10)
        static let disposed = InternalState(rawValue: 1 << 30)
        static let error = InternalState(rawValue: 1 << 31)

        static let waiting = [.waitingForData, waitingForDataAfterSeek, .rebuffering]
    }
}

/// Helper method that returns `AudioPlayerState` and `StopReason` based on the given `InternalState`
/// - Parameter internalState: A value of `InternalState`
/// - Returns: A tuple of `(AudioPlayerState, AudioPlayerStopReason)`
func playerStateAndStopReason(for internalState: AudioPlayer.InternalState) -> (state: AudioPlayerState,
                                                                                stopReason: AudioPlayerStopReason)
{
    switch internalState {
    case .initial:
        return (.ready, .none)
    case .running, .playing, .waitingForDataAfterSeek:
        return (.playing, .none)
    case .pendingNext, .rebuffering, .waitingForData:
        return (.bufferring, .none)
    case .stopped:
        return (.stopped, .userAction)
    case .paused:
        return (.paused, .none)
    case .disposed:
        return (.disposed, .userAction)
    case .error:
        return (.error, .error)
    default:
        return (.ready, .none)
    }
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
    case streamParseBytesFailure(AudioFileStreamError)
    case audioSystemError(AudioSystemError)
    case codecError
    case dataNotFound
    case networkError(NetworkError)
    case other

    public var errorDescription: String? {
        switch self {
        case let .streamParseBytesFailure(status):
            return "Couldn't parse the bytes from the stream. Status: \(status)"
        case let .audioSystemError(error):
            return error.errorDescription
        case .codecError:
            return "Codec error while parsing data packets"
        case .dataNotFound:
            return "No data supplied from network stream"
        case let .networkError(error):
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
    case fileStreamError(AudioFileStreamError)
    case converterError(AudioConverterError)

    public var errorDescription: String? {
        switch self {
        case .engineFailure: return "Audio engine couldn't start"
        case .playerNotFound: return "Player not found"
        case .playerStartError: return "Player couldn't start"
        case let .fileStreamError(error):
            return "Audio file stream error'd: \(error)"
        case let .converterError(error):
            return "Audio converter error'd: \(error)"
        }
    }
}
