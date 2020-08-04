//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import CoreAudio
import AVFoundation

internal var maxFramesPerSlice: UInt32 = 8192
internal var mChannelsPerFrame: UInt32 = UnitDescriptions.canonicalAudioStream.mChannelsPerFrame

public final class AudioPlayer {
    
    public weak var delegate: AudioPlayerDelegate?
    
    public var muted: Bool {
        get { playerContext.muted }
        set { playerContext.muted = newValue }
    }
    
    /// The volume of the audio
    ///
    /// Defaults to 1.0. Valid ranges are 0.0 to 1.0
    /// The value is restricted from 0.0 to 1.0
    public var volume: Float32 {
        get { self.audioEngine.mainMixerNode.outputVolume }
        set { self.audioEngine.mainMixerNode.outputVolume = min(1.0, max(0.0, newValue)) }
    }
    
    public var rate: Float {
        get { self.rateNode.rate }
        set { self.rateNode.rate = newValue }
    }
    
    public var state: AudioPlayerState {
        playerContext.state
    }
    
    public var stopReason: AudioPlayerStopReason {
        playerContext.stopReason
    }
    
    public let configuration: AudioPlayerConfiguration
    
    private var audioFormat: AVAudioFormat = {
        AVAudioFormat(streamDescription: &UnitDescriptions.canonicalAudioStream)!
    }()
    
    private var stateBeforePaused: PlayerInternalState = .initial
    
    internal let audioEngine = AVAudioEngine()
    private(set) internal var player: AVAudioUnit?
    private(set) internal var converter: AVAudioUnit?
    internal let rateNode = AVAudioUnitTimePitch()
    internal var audioFileStream: AudioFileStreamID? = nil
    internal let equalizer = AVAudioUnitEQ()
    
    internal var isEngineRunning: Bool { audioEngine.isRunning }
    
    internal var rendererContext: AudioRendererContext
    internal var playerContext: AudioPlayerContext
    
    internal let fileStreamProcessor: AudioFileStreamProcessor
    internal let playerRenderProcessor: AudioPlayerRenderProcessor
    
    internal var audioReadSource: DispatchTimerSource
    internal let underlyingQueue = DispatchQueue(label: "streaming.core.queue", qos: .userInitiated)
    internal let propertiesQueue = DispatchQueue(label: "streaming.core.queue.properties", qos: .userInitiated)
    internal var audioSemaphore = DispatchSemaphore(value: 0)
    internal var sourceQueue: DispatchQueue
    
    private(set) lazy var networking = NetworkingClient()
    internal var audioSource: AudioStreamSource?
    
    internal var entriesQueue: PlayerQueueEntries
    
    public init(configuration: AudioPlayerConfiguration = .default) {
        self.configuration = configuration.normalizeValues()
        
        self.rendererContext = AudioRendererContext(configuration: configuration)
        self.playerContext = AudioPlayerContext(configuration: configuration, targetQueue: propertiesQueue)
        
        self.entriesQueue = PlayerQueueEntries()
        
        self.sourceQueue = DispatchQueue(label: "source.queue", qos: .userInitiated, target: underlyingQueue)
        self.audioReadSource = DispatchTimerSource(interval: .milliseconds(500), queue: sourceQueue)
        
        self.fileStreamProcessor = AudioFileStreamProcessor(playerContext: playerContext,
                                                            rendererContext: rendererContext,
                                                            semaphore: audioSemaphore)
        
        self.playerRenderProcessor = AudioPlayerRenderProcessor(playerContext: playerContext,
                                                                rendererContext: rendererContext,
                                                                semaphore: audioSemaphore)
        
        self.configPlayerContext()
        self.configPlayerNode()
        self.setupEngine()
    }
    
    deinit {
        // todo more stuff to release...
        rendererContext.clean()
    }
    
    // MARK: Public
    
    public func play(url: URL) {
        play(url: url, headers: [:])
    }
    
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
        playerContext.internalState = .pendingNext
        
        checkRenderWaitingAndNotifyIfNeeded()
        sourceQueue.async { [weak self] in
            try? self?.startEngineIfNeeded()
            self?.processSource()
            self?.startReadProcessFromSourceIfNeeded()
        }
    }
    
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
    
    public func resume() {
        if playerContext.internalState == .paused {
            playerContext.setInternalState(to: stateBeforePaused)
            // check if seek time requested and reset buffers
            do {
                try self.audioEngine.start()
            } catch {
                print("resuming audio engine failed: \(error)")
            }
            self.startPlayer(resetBuffers: false)
            startReadProcessFromSourceIfNeeded()
        }
    }
    
    public func duration() -> Double {
        guard playerContext.internalState != .pendingNext else { return 0 }
        playerContext.entriesLock.lock(); defer { playerContext.entriesLock.unlock() }
        guard let entry = playerContext.currentReadingEntry else { return 0 }
        
        let entryDuration = entry.duration()
        let progress = self.progress()
        if entryDuration < progress && entryDuration > 0 {
            return progress
        }
        return entryDuration
    }
    
    public func progress() -> Double {
        // TODO: account for seek request
        guard playerContext.internalState != .pendingNext else { return 0 }
        guard let entry = playerContext.currentReadingEntry else { return 0 }
        return Double(entry.seekTime) + (Double(entry.framesState.played) / Double(audioFormat.sampleRate))
    }
    
    // MARK: Private
    
    private func setupEngine() {
        do {
            audioEngine.stop()
            playerRenderProcessor.renderBlock = audioEngine.manualRenderingBlock
            
            let audioFormat = AVAudioFormat(streamDescription: &UnitDescriptions.canonicalAudioStream)!
            
            try audioEngine.enableManualRenderingMode(.realtime,
                                                      format: audioFormat,
                                                      maximumFrameCount: AVAudioFrameCount(maxFramesPerSlice))
            
            let success = audioEngine.inputNode.setManualRenderingInputPCMFormat(audioFormat,
                                                                                 inputBlock: manualRenderingInput)
            guard success else {
                assertionFailure("failure setting manual rendering mode")
                return
            }
            attachAndConnectNodes(format: audioFormat)
            
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            Logger.error("⚠️ error setuping audio engine: %@", category: .generic, args: error.localizedDescription)
        }
    }
    
    internal func manualRenderingInput(frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        return playerRenderProcessor.inRender(inNumberFrames: frameCount)
    }
    
    private func configPlayerNode() {
        let playerRenderProcessor = self.playerRenderProcessor
        AVAudioUnit.createAudioUnit(with: UnitDescriptions.output) { [weak self] result in
            switch result {
                case .success(let unit):
                    self?.player = unit
                case .failure(let error):
                    assertionFailure("couldn't create player unit: \(error)")
            }
        }
        
        guard let player = player else {
            raiseUnxpected(error: .audioSystemError(.playerNotFound))
            return
        }
        
        playerRenderProcessor.attachCallback(on: player)
    }
    
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
    
    private func attachAndConnectNodes(format: AVAudioFormat) {
        audioEngine.attach(equalizer)
        audioEngine.attach(rateNode)
        
        let eqFormat = equalizer.outputFormat(forBus: 0)
        audioEngine.connect(audioEngine.inputNode, to: rateNode, format: nil)
        audioEngine.connect(rateNode, to: equalizer, format: eqFormat)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format:  nil)
    }
    
    private func startEngineIfNeeded() throws {
        guard !isEngineRunning else {
            Logger.debug("engine already running 🛵", category: .generic)
            return
        }
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
    
    private func stopEngine(reason: AudioPlayerStopReason) {
        guard isEngineRunning else {
            Logger.debug("already already stopped 🛑", category: .generic)
            return
        }
        audioEngine.stop()
        player?.auAudioUnit.stopHardware()
        rendererContext.resetBuffers()
        playerContext.internalState = .stopped
        playerContext.stopReason = reason
        Logger.debug("engine stopped 🛑", category: .generic)
    }
    
    private func startReadProcessFromSourceIfNeeded() {
        guard audioReadSource.state != .resumed else { return }
        audioReadSource.add { [weak self] in
            self?.processSource()
        }
        audioReadSource.resume()
    }
    
    private func stopReadProccessFromSource() {
        audioReadSource.suspend()
        audioReadSource.removeHandler()
    }
    
    private func startPlayer(resetBuffers: Bool) {
        guard let player = player else { return }
        if resetBuffers {
            rendererContext.resetBuffers()
        }
        if !isEngineRunning && !player.auAudioUnit.isRunning { return }
        do {
            try player.auAudioUnit.startHardware()
        } catch {
            raiseUnxpected(error: .audioSystemError(.playerStartError))
        }
        // TODO: stop system background task
        
    }
    
    private func processSource() {
        guard !playerContext.disposedRequested else { return }
        // don't process on paused but don't stop the run loop
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
            let count = Int(rendererContext.bufferTotalFrameCount * rendererContext.bufferFrameSizeInBytes)
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
                let progress = Double(progressInFrames) / UnitDescriptions.canonicalAudioStream.mSampleRate
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
    
    private func checkRenderWaitingAndNotifyIfNeeded() {
        guard rendererContext.waiting else { return }
        audioSemaphore.signal()
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
        self.delegate?.audioPlayerDidReadMetadata(player: self, metadata: data)
    }
    
}
