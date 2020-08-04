//
//  Created by Dimitrios Chatzieleftheriou on 03/08/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

public protocol AudioPlayerDelegate: class {
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
    /// Tells the delegate when an unexpected error occured.
    /// - note: Probably a good time to recreate the player when this occurs
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError)
    
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId])
    
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String])
}
