//
//  Created by Dimitrios Chatzieleftheriou on 16/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class AudioPlayerContext {
    
    var stopReason: AudioPlayerStopReason = .none
    
    var state: AudioPlayerState = .ready
    
    var muted: Bool
    
    /// This is the player's internal state to use
    /// - NOTE: Do not use directly instead use the `internalState` to set and get the property
    /// or the `setInternalState(to:when:)`method
    private let stateLock = UnfairLock()
    private var __playerInternalState: PlayerInternalState = .initial
    
    var internalState: PlayerInternalState {
        get { __playerInternalState }
        set { setInternalState(to: newValue) }
    }
    
    let entriesLock = UnfairLock()
    
    var currentReadingEntry: AudioEntry?
    var currentPlayingEntry: AudioEntry?
    
    var disposedRequested: Bool = false
    
    let configuration: AudioPlayerConfiguration
    
    init(configuration: AudioPlayerConfiguration, targetQueue: DispatchQueue) {
        self.configuration = configuration
        self.muted = false
    }
    
    /// Sets the internal state if given the `inState` will be evaluated before assignment occurs.
    /// This also convenvienlty sets the `stopReason` as well
    /// - parameter state: The new `PlayerInternalState`
    /// - parameter inState: If the `inState` expression is not nil, the internalState will be set if the evaluated expression is `true`
    /// - NOTE: This sets the underlying `__playerInternalState` variable
    internal func setInternalState(to state: PlayerInternalState,
                                   when inState: ((PlayerInternalState) -> Bool)? = nil) {
        let newValues = playerStateAndStopReason(for: state)
        stateLock.lock(); defer { stateLock.unlock() }
        stopReason = newValues.stopReason
        guard state != internalState else { return }
        if let inState = inState, !inState(internalState) {
            return
        }
        __playerInternalState = state
        let previousPlayerState = self.state
        if newValues.state != previousPlayerState {
            self.state = newValues.state
        }
    }
    
}
