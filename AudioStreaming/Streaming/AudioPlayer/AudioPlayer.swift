//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import CoreAudio
import AVFoundation

public final class AudioPlayer {
    
    public weak var delegate: AudioPlayerDelegate?
    
    public var muted: Bool {
        get { playerContext.muted }
        set { playerContext.$muted.write { $0 = newValue } }
    }
    
    /// The volume of the audio
    ///
    /// Defaults to 1.0. Valid ranges are 0.0 to 1.0
    /// The value is restricted from 0.0 to 1.0
    public var volume: Float32 {
        get { self.audioEngine.mainMixerNode.outputVolume }
        set { self.audioEngine.mainMixerNode.outputVolume = min(1.0, max(0.0, newValue)) }
    }
    /// The playback rate of the player.
    ///
    /// The default value is 1.0. Valid ranges are 1/32 to 32.0
    ///
    /// **NOTE:** Setting this to a value of more than `1.0` while playing a live broadcast stream would
    /// result in the audio being exhausted before it could fetch new data.
    public var rate: Float {
        get { self.rateNode.rate }
        set { self.rateNode.rate = newValue }
    }
    
    /// The player's current state.
    public var state: AudioPlayerState {
        playerContext.state
    }
    
    /// Indicates the reason that the player stopped.
    public var stopReason: AudioPlayerStopReason {
        playerContext.stopReason
    }
    
    /// The current configuration of the player.
    public let configuration: AudioPlayerConfiguration
    
    /// An `AVAudioFormat` object for the canonical audio stream
    private var audioFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 44100.0, channels: 2, interleaved: true)!
    }()
    
    /// Keeps track of the player's state before being paused.
    private var stateBeforePaused: PlayerInternalState = .initial
    
    /// The underlying `AVAudioEngine` object
    let audioEngine = AVAudioEngine()
    /// An `AVAudioUnit` object that represents the audio player
    private(set) var player: AVAudioUnit?
    /// An `AVAudioUnitTimePitch` that controls the playback rate of the audio engine
    let rateNode = AVAudioUnitTimePitch()
    
    /// A Boolean value that indicates whether the audio engine is running.
    /// `true` if the engine is running, otherwise, `false`
    var isEngineRunning: Bool { audioEngine.isRunning }
    
    /// An object representing the context of the audio render.
    /// Holds the audio buffer and in/out lists as required by the audio rendering
    let rendererContext: AudioRendererContext
    /// An object representing the context of the player.
    /// Holds the player's state, current playing and reading entries.
    let playerContext: AudioPlayerContext
    
    let fileStreamProcessor: AudioFileStreamProcessor
    let playerRenderProcessor: AudioPlayerRenderProcessor
    
    private let audioReadSource: DispatchTimerSource
    private let underlyingQueue = DispatchQueue(label: "streaming.core.queue", qos: .userInitiated)
    private let sourceQueue: DispatchQueue
    
    private(set) lazy var networking = NetworkingClient()
    var audioSource: AudioStreamSource?
    
    var entriesQueue: PlayerQueueEntries
    
    public init(configuration: AudioPlayerConfiguration = .default) {
        self.configuration = configuration.normalizeValues()
        
        self.rendererContext = AudioRendererContext(configuration: configuration, audioFormat: audioFormat)
        self.playerContext = AudioPlayerContext()
        
        self.entriesQueue = PlayerQueueEntries()
        
        self.sourceQueue = DispatchQueue(label: "source.queue", qos: .userInitiated, target: underlyingQueue)
        self.audioReadSource = DispatchTimerSource(interval: .milliseconds(500), queue: sourceQueue)
        
        self.fileStreamProcessor = AudioFileStreamProcessor(playerContext: playerContext,
                                                            rendererContext: rendererContext,
                                                            audioFormat: audioFormat)
        
        self.playerRenderProcessor = AudioPlayerRenderProcessor(playerContext: playerContext,
                                                                rendererContext: rendererContext,
                                                                audioFormat: audioFormat)
        
        self.configPlayerContext()
        self.configPlayerNode()
        self.setupEngine()
    }
    
    deinit {
        // todo more stuff to release...
        rendererContext.clean()
    }
    
    // MARK: Public
    
    /// Starts the audio playback for the given URL
    ///
    /// - parameter url: A `URL` specifying the audio context to be played
    public func play(url: URL) {
        play(url: url, headers: [:])
    }
    
    /// Starts the audio playback for the given URL
    ///
    /// - parameter url: A `URL` specifying the audio context to be played.
    /// - parameter headers: A `Dictionary` specifying any additional headers to be pass to the network request.
    public func play(url: URL, headers: [String: String]) {
        let audioSource = RemoteAudioSource(networking: self.networking,
                                            url: url,
                                            sourceQueue: sourceQueue,
                                            readBufferSize: configuration.readBufferSize,
                                            httpHeaders: headers)
        let entry = AudioEntry(source: audioSource,
                               entryId: AudioEntryId(id: url.absoluteString))
        audioSource.delegate = self
        clearQueue()
        entriesQueue.enqueue(item: entry, type: .upcoming)
        
        checkRenderWaitingAndNotifyIfNeeded()
        sourceQueue.async { [weak self] in
            guard let self = self else { return }
            self.playerContext.internalState = .pendingNext
            do {
                try self.startEngineIfNeeded()
            } catch {
                self.raiseUnxpected(error: .audioSystemError(.engineFailure))
            }
            self.processSource()
            self.startReadProcessFromSourceIfNeeded()
        }
    }
    
    /// Stops the audio playback
    public func stop() {
        guard playerContext.internalState != .stopped else { return }
        
        stopEngine(reason: .userAction)
        stopReadProccessFromSource()
        checkRenderWaitingAndNotifyIfNeeded()
        sourceQueue.async { [weak self] in
            guard let self = self else { return }
            self.playerContext.currentReadingEntry?.source.delegate = nil
            self.playerContext.currentReadingEntry?.source.removeFromQueue()
            self.playerContext.currentReadingEntry?.source.close()
            if let playingEntry = self.playerContext.currentPlayingEntry {
                self.processFinishPlaying(entry: playingEntry, with: nil)
            }
            
            self.clearQueue()
            self.playerContext.currentReadingEntry = nil
            self.playerContext.currentPlayingEntry = nil
            
            self.processSource()
        }
    }
    
    /// Pauses the audio playback
    public func pause() {
        if playerContext.internalState != .paused && playerContext.internalState.contains(.running) {
            stateBeforePaused = playerContext.internalState
            playerContext.setInternalState(to: .paused)
            
            pauseEngine()
            sourceQueue.async { [weak self] in
                self?.processSource()
            }
            stopReadProccessFromSource()
        }
    }
    /// Resumes the audio playback, if previous paused
    public func resume() {
        guard playerContext.internalState == .paused else { return }
        playerContext.setInternalState(to: stateBeforePaused)
        // check if seek time requested and reset buffers
        do {
            try startEngine()
        } catch {
            Logger.debug("resuming audio engine failed: %@", category: .generic, args: error.localizedDescription)
        }
        
        startPlayer(resetBuffers: false)
        startReadProcessFromSourceIfNeeded()
    }
    
    /// The duration of the audio, in seconds.
    ///
    /// **NOTE** In live audio playback this will be `0.0`
    ///
    /// - Returns: A `Double` value indicating the total duration.
    public func duration() -> Double {
        guard playerContext.internalState != .pendingNext else { return 0 }
        playerContext.entriesLock.lock(); defer { playerContext.entriesLock.unlock() }
        guard let entry = playerContext.currentPlayingEntry else { return 0 }
        
        let entryDuration = entry.duration()
        let progress = self.progress()
        if entryDuration < progress && entryDuration > 0 {
            return progress
        }
        return entryDuration
    }
    
    /// The progress of the audio playback, in seconds.
    public func progress() -> Double {
        // TODO: account for seek request
        guard playerContext.internalState != .pendingNext else { return 0 }
        guard let entry = playerContext.currentPlayingEntry else { return 0 }
        return Double(entry.seekTime) + (Double(entry.framesState.played) / audioFormat.sampleRate)
    }
    
    // MARK: Private
    
    /// Setups the audio engine with manual rendering mode.
    private func setupEngine() {
        do {
            // audio engine must be stop before enabling manualRendering mode.
            audioEngine.stop()
            playerRenderProcessor.renderBlock = audioEngine.manualRenderingBlock
            
            try audioEngine.enableManualRenderingMode(.realtime,
                                                      format: audioFormat,
                                                      maximumFrameCount: maxFramesPerSlice)
            
            let inputBlock = { [weak self] frameCount -> UnsafePointer<AudioBufferList>? in
                self?.playerRenderProcessor.inRender(inNumberFrames: frameCount)
            }
            
            let success = audioEngine.inputNode.setManualRenderingInputPCMFormat(audioFormat,
                                                                                 inputBlock: inputBlock)
            guard success else {
                assertionFailure("failure setting manual rendering mode")
                return
            }
            attachAndConnectNodes()
            
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            Logger.error("⚠️ error setuping audio engine: %@", category: .generic, args: error.localizedDescription)
        }
    }
    
    /// Creates and configures an `AVAudioUnit` with an output configuration
    /// and assigns it to the `player` variable.
    private func configPlayerNode() {
        let playerRenderProcessor = self.playerRenderProcessor
        AVAudioUnit.createAudioUnit(with: UnitDescriptions.output) { [weak self] result in
            guard let self = self else { return }
            switch result {
                case .success(let unit):
                    self.player = unit
                    playerRenderProcessor.attachCallback(on: unit, audioFormat: self.audioFormat)
                case .failure(let error):
                    assertionFailure("couldn't create player unit: \(error)")
                    self.raiseUnxpected(error: .audioSystemError(.playerNotFound))
            }
        }
    }
    
    /// Attaches callbacks to the `playerContext` and `renderProcessor`.
    private func configPlayerContext() {
        self.playerContext.stateChanged = { [weak self] oldValue, newValue in
            guard let self = self else { return }
            self.delegate?.audioPlayerStateChanged(player: self, with: newValue, previous: oldValue)
        }
        
        self.playerRenderProcessor.audioFinished = { [weak self] entry in
            guard let self = self else { return }
            self.sourceQueue.async {
                let nextEntry = self.entriesQueue.dequeue(type: .buffering)
                self.processFinishPlaying(entry: entry, with: nextEntry)
                self.processSource()
            }
        }
    }
    
    /// Attaches and connect nodes to the `AudioEngine`.
    private func attachAndConnectNodes() {
        audioEngine.attach(rateNode)
        
        audioEngine.connect(audioEngine.inputNode, to: rateNode, format: nil)
        audioEngine.connect(rateNode, to: audioEngine.mainMixerNode, format:  nil)
    }
    
    /// Starts the engine, if not already running.
    ///
    /// - Throws: An `Error` when failed to start the engine.
    private func startEngineIfNeeded() throws {
        guard !isEngineRunning else {
            Logger.debug("engine already running 🛵", category: .generic)
            return
        }
        try startEngine()
    }
    
    /// Force starts the engine
    ///
    /// - Throws: An `Error` when failed to start the engine.
    private func startEngine() throws {
        try audioEngine.start()
        Logger.debug("engine started 🛵", category: .generic)
    }
    
    /// Pauses the audio engine and stops the player's hardware
    private func pauseEngine() {
        guard isEngineRunning else { return }
        audioEngine.pause()
        player?.auAudioUnit.stopHardware()
        Logger.debug("engine paused ⏸", category: .generic)
    }
    
    /// Stops the audio engine and the player's hardware
    ///
    /// - parameter reason: A value of `AudioPlayerStopReason` indicating the reason the engine stopped.
    private func stopEngine(reason: AudioPlayerStopReason) {
        guard isEngineRunning else {
            Logger.debug("already already stopped 🛑", category: .generic)
            return
        }
        audioEngine.stop()
        player?.auAudioUnit.stopHardware()
        rendererContext.resetBuffers()
        playerContext.internalState = .stopped
        playerContext.$stopReason.write { $0 = reason }
        Logger.debug("engine stopped 🛑", category: .generic)
    }
    
    /// Starts the timer of `audioReadSource` for proccesing the source read stream
    ///
    /// This calls `processSource` method every `500 ms`
    ///
    private func startReadProcessFromSourceIfNeeded() {
        guard audioReadSource.state != .activated else { return }
        audioReadSource.add { [weak self] in
            self?.processSource()
        }
        audioReadSource.activate()
    }
    
    /// Stops and removes the handler from the timer, @see `audioReadSource`
    private func stopReadProccessFromSource() {
        audioReadSource.suspend()
        audioReadSource.removeHandler()
    }
    
    /// Starts the audio player, reseting the buffers if requested
    ///
    /// - parameter resetBuffers: A `Bool` value indicating if the buffers should be reset, prior starting the player.
    private func startPlayer(resetBuffers: Bool) {
        guard let player = player else { return }
        if resetBuffers {
            rendererContext.resetBuffers()
        }
        if !isEngineRunning && !player.auAudioUnit.isRunning {
            Logger.debug("trying to start the player when audio engine and player are already running", category: .generic)
            return
        }
        do {
            try player.auAudioUnit.startHardware()
        } catch {
            raiseUnxpected(error: .audioSystemError(.playerStartError))
        }
        // TODO: stop system background task
        
    }
    
    /// Processing the `playerContext` state to ensure correct behavior of playing/stop/seek
    private func processSource() {
        guard !playerContext.disposedRequested else { return }
        guard playerContext.internalState != .paused else { return }
        
        if playerContext.internalState == .pendingNext {
            let entry = entriesQueue.dequeue(type: .upcoming)
            playerContext.internalState = .waitingForData
            setCurrentReading(entry: entry, startPlaying: true, shouldClearQueue: true)
            rendererContext.resetBuffers()
        }
        else if playerContext.currentReadingEntry == nil {
            if entriesQueue.count(for: .upcoming) > 0 {
                let entry = entriesQueue.dequeue(type: .upcoming)
                let shouldStartPlaying = playerContext.currentPlayingEntry == nil
                playerContext.internalState = .waitingForData
                setCurrentReading(entry: entry, startPlaying: shouldStartPlaying, shouldClearQueue: true)
            } else if playerContext.currentPlayingEntry == nil {
                if playerContext.internalState != .stopped {
                    stopReadProccessFromSource()
                    stopEngine(reason: .eof)
                }
            }
        }
    }
    
    private func setCurrentReading(entry: AudioEntry?, startPlaying: Bool, shouldClearQueue: Bool) {
        guard let entry = entry else { return }
        Logger.debug("Setting current reading entry to: %@", category: .generic, args: entry.debugDescription)
        if startPlaying {
            let count = Int(rendererContext.bufferContext.totalFrameCount * rendererContext.bufferContext.sizeInBytes)
            memset(rendererContext.audioBuffer.mData, 0, count)
        }
        
        fileStreamProcessor.closeFileStreamIfNeeded()
        
        if let readingEntry = playerContext.currentReadingEntry {
            readingEntry.source.delegate = nil
            readingEntry.source.removeFromQueue()
            readingEntry.source.close()
        }
        
        playerContext.entriesLock.around {
            playerContext.currentReadingEntry = entry
        }
        playerContext.currentReadingEntry?.source.delegate = self
        playerContext.currentReadingEntry?.source.setup()
        playerContext.currentReadingEntry?.source.seek(at: 0)
        
        if startPlaying {
            if shouldClearQueue {
                clearQueue()
            }
            processFinishPlaying(entry: playerContext.currentPlayingEntry, with: entry)
            startPlayer(resetBuffers: true)
        } else {
            entriesQueue.enqueue(item: entry, type: .buffering)
        }
    }
    
    private func processFinishPlaying(entry: AudioEntry?, with nextEntry: AudioEntry?) {
        guard entry == playerContext.currentPlayingEntry else { return }
        
        let isPlayingSameItemProbablySeek = playerContext.currentPlayingEntry == nextEntry
        
        let notifyDelegateEntryFinishedPlaying: (AudioEntry?, Bool) -> Void = { [weak self] entry, probablySeek in
            guard let self = self else { return }
            if let entry = entry, !isPlayingSameItemProbablySeek {
                let entryId = entry.id
                let progressInFrames = entry.progressInFrames()
                let progress = Double(progressInFrames) / self.audioFormat.basicStreamDescription.mSampleRate
                let duration = entry.duration()
                
                asyncOnMain {
                    self.delegate?.audioPlayerDidFinishPlaying(player: self, entryId: entryId, stopReason: self.stopReason, progress: progress, duration: duration)
                }
            }
        }
        
        if let nextEntry = nextEntry {
            if !isPlayingSameItemProbablySeek {
                sourceQueue.async {
                    nextEntry.seekTime = 0
                }
                // seek requested no.
            }
            playerContext.entriesLock.around {
                playerContext.currentPlayingEntry = nextEntry
            }
            let playingQueueEntryId = nextEntry.id
            
            notifyDelegateEntryFinishedPlaying(entry, isPlayingSameItemProbablySeek)
            if !isPlayingSameItemProbablySeek {
                playerContext.internalState = .waitingForData
                
                asyncOnMain { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.audioPlayerDidStartPlaying(player: self, with: playingQueueEntryId)
                }
            }
        } else {
            notifyDelegateEntryFinishedPlaying(entry, isPlayingSameItemProbablySeek)
            playerContext.entriesLock.around {
                playerContext.currentPlayingEntry = nil
            }
        }
        processSource()
        checkRenderWaitingAndNotifyIfNeeded()
    }
    
    /// Clears pending queues and informs the delegate
    private func clearQueue() {
        let pendingItems = entriesQueue.pendingEntriesId()
        entriesQueue.removeAll()
        if !pendingItems.isEmpty {
            asyncOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioPlayerDidCancel(player: self, queuedItems: pendingItems)
            }
        }
    }
    
    /// Signals the packet process
    private func checkRenderWaitingAndNotifyIfNeeded() {
        guard rendererContext.waiting else { return }
        rendererContext.packetsSemaphore.signal()
    }
    
    private func raiseUnxpected(error: AudioPlayerError) {
        playerContext.internalState = .error
        // todo raise on main thread from playback thread
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioPlayerUnexpectedError(player: self, error: error)
        }
        Logger.error("Error: %@", category: .generic, args: error.localizedDescription)
    }
    
}

extension AudioPlayer: AudioStreamSourceDelegate {
    
    func dataAvailable(source: AudioStreamSource) {
        guard playerContext.currentReadingEntry?.source === source else { return }
        guard source.hasBytesAvailable else { return }
        
        let read = source.read(into: rendererContext.readBuffer, size: rendererContext.readBufferSize)
        guard read != 0 else { return }
        
        if !fileStreamProcessor.isFileStreamOpen {
            guard fileStreamProcessor.openFileStream(with: source.audioFileHint) == noErr else {
                raiseUnxpected(error: .audioSystemError(.fileStreamError))
                return
            }
        }
        guard read > 0 else {
            // ios will shutdown network connections when on background
            let position = source.position
            source.seek(at: position)
            return
        }
        
        // TODO: check for discontinuous stream and add flag
        if fileStreamProcessor.isFileStreamOpen {
            guard fileStreamProcessor.parseFileSteamBytes(buffer: rendererContext.readBuffer, size: read) == noErr else {
                if source === playerContext.currentPlayingEntry?.source {
                    raiseUnxpected(error: .streamParseBytesFailure)
                }
                return
            }
            
            playerContext.currentReadingEntry?.lock.lock()
            if playerContext.currentReadingEntry === nil {
                source.removeFromQueue()
                source.close()
            }
            playerContext.currentReadingEntry?.lock.unlock()
        }
    }
    
    func errorOccured(source: AudioStreamSource) {
        guard let entry = playerContext.currentReadingEntry, entry.source === source else { return }
        raiseUnxpected(error: .dataNotFound)
    }
    
    func endOfFileOccured(source: AudioStreamSource) {
        guard playerContext.currentReadingEntry != nil || playerContext.currentReadingEntry?.source === source else {
            source.delegate = nil
            source.removeFromQueue()
            source.close()
            return
        }
        let queuedItemId = playerContext.currentReadingEntry?.id
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            guard let itemId = queuedItemId else { return }
            self.delegate?.audioPlayerDidFinishBuffering(player: self, with: itemId)
        }
        
        guard let readingEntry = playerContext.currentReadingEntry else {
            source.delegate = nil
            source.removeFromQueue()
            source.close()
            return
        }
        
        readingEntry.framesState.lastFrameQueued = readingEntry.framesState.queued
        
        readingEntry.source.delegate = nil
        readingEntry.source.removeFromQueue()
        readingEntry.source.close()
        
        playerContext.entriesLock.lock()
        playerContext.currentReadingEntry = nil
        playerContext.entriesLock.unlock()
        processSource()
    }
    
    func metadataReceived(data: [String : String]) {
        asyncOnMain { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioPlayerDidReadMetadata(player: self, metadata: data)
        }
    }
    
}
