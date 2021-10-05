//
//  Created by Dimitrios Chatzieleftheriou on 16/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class AudioPlayerContext {
    var stopReason: Protected<AudioPlayerStopReason>

    var state: Protected<AudioPlayerState>
    var stateChanged: ((_ oldState: AudioPlayerState, _ newState: AudioPlayerState) -> Void)?

    var muted: Protected<Bool>

    var internalState: AudioPlayer.InternalState {
        playerInternalState.value
    }

    let entriesLock: UnfairLock
    var audioReadingEntry: AudioEntry?
    var audioPlayingEntry: AudioEntry?

    /// This is the player's internal state to use
    /// - NOTE: Do not use directly instead use the `internalState` to set and get the property
    /// or the `setInternalState(to:when:)`method
    private var playerInternalState = Protected<AudioPlayer.InternalState>(.initial)

    init() {
        stopReason = Protected<AudioPlayerStopReason>(.none)
        state = Protected<AudioPlayerState>(.ready)
        muted = Protected<Bool>(false)
        entriesLock = UnfairLock()
    }

    /// Sets the internal state if given the `inState` will be evaluated before assignment occurs.
    /// This also convenvienlty sets the `stopReason` as well
    /// - parameter state: The new `PlayerInternalState`
    /// - parameter inState: If the `inState` expression is not nil, the internalState will be set if the evaluated expression is `true`
    /// - NOTE: This sets the underlying `__playerInternalState` variable
    internal func setInternalState(to state: AudioPlayer.InternalState,
                                   when inState: ((AudioPlayer.InternalState) -> Bool)? = nil)
    {
        let newValues = playerStateAndStopReason(for: state)
        stopReason.write { $0 = newValues.stopReason }
        guard state != internalState else { return }
        if let inState = inState, !inState(internalState) {
            return
        }
        playerInternalState.write { $0 = state }
        let previousPlayerState = self.state.value
        if newValues.state != previousPlayerState {
            self.state.write { $0 = newValues.state }
            stateChanged?(previousPlayerState, newValues.state)
        }
    }
}
