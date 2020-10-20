//
//  Created by Dimitrios Chatzieleftheriou on 16/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class AudioPlayerContext {
    
    @Protected
    var stopReason: AudioPlayerStopReason = .none
    
    @Protected
    var state: AudioPlayerState = .ready {
        didSet {
            stateChanged?(oldValue, state)
        }
    }
    var stateChanged: ((_ oldState: AudioPlayerState, _ newState: AudioPlayerState) -> Void)?
    
    @Protected
    var muted: Bool = false
    
    /// This is the player's internal state to use
    /// - NOTE: Do not use directly instead use the `internalState` to set and get the property
    /// or the `setInternalState(to:when:)`method
    @Protected
    private var __playerInternalState: AudioPlayer.InternalState = .initial
    
    var internalState: AudioPlayer.InternalState {
        get { __playerInternalState }
        set { setInternalState(to: newValue) }
    }
    
    /// Shared lock for `currentReadingEntry` and `currentPlayingEntry`
    let entriesLock = UnfairLock()
    
    var audioReadingEntry: AudioEntry?
    var audioPlayingEntry: AudioEntry?
    
    var disposedRequested: Bool
    
    init() {
        self.disposedRequested = false
    }
    
    /// Sets the internal state if given the `inState` will be evaluated before assignment occurs.
    /// This also convenvienlty sets the `stopReason` as well
    /// - parameter state: The new `PlayerInternalState`
    /// - parameter inState: If the `inState` expression is not nil, the internalState will be set if the evaluated expression is `true`
    /// - NOTE: This sets the underlying `__playerInternalState` variable
    internal func setInternalState(to state: AudioPlayer.InternalState,
                                   when inState: ((AudioPlayer.InternalState) -> Bool)? = nil) {
        let newValues = playerStateAndStopReason(for: state)
        $stopReason.write { reason in
            reason = newValues.stopReason
        }
        guard state != internalState else { return }
        if let inState = inState, !inState(internalState) {
            return
        }
        $__playerInternalState.write { internalState in
            internalState = state
        }
        let previousPlayerState = self.state
        if newValues.state != previousPlayerState {
            $state.write { $0 = newValues.state }
        }
    }
    
}
