//
//  Created by Dimitrios Chatzieleftheriou on 03/08/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

public protocol AudioPlayerDelegate: AnyObject {
    /// Tells the delegate that the player started player
    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId)

    /// Tells the delegate that the player finished buffering for an entry.
    /// - note: May be called multiple times when seek is requested
    func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId)

    /// Tells the delegate that the state has changed passing both the new state and previous.
    func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState)

    /// Tells the delegate that an entry has finished
    func audioPlayerDidFinishPlaying(player: AudioPlayer,
                                     entryId: AudioEntryId,
                                     stopReason: AudioPlayerStopReason,
                                     progress: Double,
                                     duration: Double)
    /// Tells the delegate when an unexpected error occurred.
    /// - note: Probably a good time to recreate the player when this occurs
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError)

    /// Tells the delegate when cancel occurs, usually due to a stop or play (new source)
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId])

    /// Tells the delegate when a metadata read occurred from the stream.
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String])
    
    /// Tells the delegate that the audio was interrupted by system
    func audioPlayerWasInterrupted(player: AudioPlayer)
    
    /// Tells the delegate that the audio interruption did end
    func audioPlayerInterruptionDidEnd(player: AudioPlayer)
    
    /// Tells the delegate that the audio was paused due to route change
    /// automaticallyPauseOnNoisyRouteChange must be true for this to occur
    func audioPlayerDidPauseOnNoisyRouteChange(player: AudioPlayer)
    
}

/// Optionals
public extension AudioPlayerDelegate {
    
    func audioPlayerWasInterrupted(player: AudioPlayer) {
        
    }
    
    func audioPlayerInterruptionDidEnd(player: AudioPlayer) {
        
    }
    
    func audioPlayerDidPauseOnNoisyRouteChange(player: AudioPlayer) {
        
    }
    
}
