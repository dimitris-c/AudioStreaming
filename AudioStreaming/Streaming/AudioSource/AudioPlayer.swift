//
//  Created by Dimitrios Chatzieleftheriou on 01/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import CoreAudio
import AVFoundation

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
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerErrorCode)
    
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId])
    
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String])
}

internal var maxFramesPerSlice: UInt32 = 8192

func createAudioUnit(with description: AudioComponentDescription,
                     completion: @escaping (Result<AVAudioUnit, Error>) -> Void) {
    AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { (audioUnit, error) in
        if let error = error {
            completion(.failure(error))
        }
        else if let audioUnit = audioUnit {
            completion(.success(audioUnit))
        }
        else {
            completion(.failure(AudioPlayerErrorCode.audioSystemError))
        }
    }
}

public final class AudioPlayer {
    
    public weak var delegate: AudioPlayerDelegate?
    
    public var muted: Bool {
        get { playerContext.muted }
        set { playerContext.muted = newValue }
    }
    
    public var volume: Float32 {
        get { self.audioEngine.mainMixerNode.volume }
        set { self.audioEngine.mainMixerNode.volume = newValue }
    }
    
    public var rate: Float {
        get { self.rateNode.rate }
        set { self.rateNode.rate = newValue }
    }
    
    private(set) public var state: AudioPlayerState {
        didSet {
            asyncOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioPlayerStateChanged(player: self, with: self.state, previous: oldValue)
            }
        }
    }
    
    public var stopReason: AudioPlayerStopReason {
        playerContext.stopReason
    }
    
    private(set) public var configuration: AudioPlayerConfiguration
    
    private var audioFormat: AVAudioFormat = {
        AVAudioFormat(streamDescription: &UnitDescriptions.canonicalAudioStream)!
    }()
    
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
    
    fileprivate var renderBlock: AVAudioEngineManualRenderingBlock?
    
    internal var audioReadSource: DispatchTimerSource
    internal let underlyingQueue = DispatchQueue(label: "streaming.core.queue", qos: .userInitiated)
    internal let propertiesQueue = DispatchQueue(label: "streaming.core.queue.properties", qos: .userInitiated)
    internal var audioQueue: DispatchQueue
    internal var audioSemaphore = DispatchSemaphore(value: 0)
    internal var sourceQueue: DispatchQueue
    
    private(set) lazy var networking = NetworkingClient()
    internal var audioSource: AudioStreamSource?
    
    internal var entriesQueue: PlayerQueueEntries
    
    public init(configuration: AudioPlayerConfiguration = .default) {
        self.configuration = configuration
        self.state = .ready
        
        self.rendererContext = AudioRendererContext(configuration: configuration)
        self.playerContext = AudioPlayerContext(configuration: configuration, targetQueue: propertiesQueue)
        
        self.entriesQueue = PlayerQueueEntries()
        
        self.audioQueue = DispatchQueue(label: "audio.queue", qos: .userInitiated)
        self.sourceQueue = DispatchQueue(label: "source.queue", qos: .userInitiated, target: underlyingQueue)
        self.audioReadSource = DispatchTimerSource(interval: .milliseconds(500), queue: sourceQueue)
        
        self.fileStreamProcessor = AudioFileStreamProcessor(playerContext: playerContext,
                                                            rendererContext: rendererContext,
                                                            queue: audioQueue,
                                                            semaphore: audioSemaphore)
        
        self.playerRenderProcessor = AudioPlayerRenderProcessor(playerContext: playerContext,
                                                                rendererContext: rendererContext,
                                                                queue: audioQueue,
                                                                semaphore: audioSemaphore)
        
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
        let networking = self.networking
        let audioSource = RemoteAudioSource(networking: networking, url: url, sourceQueue: sourceQueue, readBufferSize: configuration.readBufferSize, httpHeaders: headers)
        let entry = AudioEntry(source: audioSource, entryId: AudioEntryId(id: url.absoluteString), underlyingQueue: propertiesQueue)
        audioSource.delegate = self
        self.clearQueue()
        self.entriesQueue.enqueue(item: entry, type: .upcoming)
        playerContext.internalState = .pendingNext
        
        self.startReadProcessFromSource()
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
            rendererContext.renderBlock = audioEngine.manualRenderingBlock
            
            let audioFormat = AVAudioFormat(streamDescription: &UnitDescriptions.canonicalAudioStream)!
            
            try audioEngine.enableManualRenderingMode(.realtime,
                                                      format: audioFormat,
                                                      maximumFrameCount: AVAudioFrameCount(maxFramesPerSlice))

            let inputBlock = { [weak self] frameCount in
                self?.manualRenderingInput(frameCount: frameCount)
            }
            
            let success = audioEngine.inputNode.setManualRenderingInputPCMFormat(audioFormat,
                                                                                 inputBlock: inputBlock)
            guard success else {
                assertionFailure("failure setting manual rendering mode")
                return
            }
            attachAndConnectNodes(format: audioFormat)
            
            audioEngine.prepare()
            try startEngine()
            
            
        } catch {
            print("⚠️ error setuping audio engine: \(error)")
        }
    }
    
    internal func manualRenderingInput(frameCount: AVAudioFrameCount) -> UnsafePointer<AudioBufferList>? {
        let inNumberFrames = frameCount
        playerContext.entriesLock.lock()
        let entry = playerContext.currentPlayingEntry
        let readingEntry = playerContext.currentReadingEntry
        playerContext.entriesLock.unlock()
        
        let state = playerContext.internalState
        
        rendererContext.lock.lock()
        
        var waitForBuffer = false
        let isMuted = playerContext.muted
        let audioBuffer = rendererContext.audioBuffer
        var bufferList = rendererContext.outAudioBufferList[0]
        let frameSizeInBytes = rendererContext.bufferFrameSizeInBytes
        let used = rendererContext.bufferUsedFrameCount
        let start = rendererContext.bufferFramesStartIndex
        let end = (rendererContext.bufferFramesStartIndex + rendererContext.bufferUsedFrameCount) % rendererContext.bufferTotalFrameCount
        let signal = rendererContext.waiting && used < rendererContext.bufferTotalFrameCount / 2
        
        if let playingEntry = entry {
            if state == .waitingForData {
                var requiredFramesToStart = rendererContext.framesRequestToStartPlaying
                if playingEntry.framesState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(playingEntry.framesState.lastFrameQueued))
                }
                if let readingEntry = readingEntry,
                   readingEntry === playingEntry && playingEntry.framesState.queued < requiredFramesToStart {
                    waitForBuffer = true
                }
            } else if state == .rebuffering {
                var requiredFramesToStart = rendererContext.framesRequiredAfterRebuffering
                let frameState = playingEntry.framesState
                if frameState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, UInt32(frameState.lastFrameQueued - frameState.queued))
                }
                if used < requiredFramesToStart {
                    waitForBuffer = true
                }
            } else if state == .waitingForDataAfterSeek {
                var requiredFramesToStart: Int = 1024
                let frameState = playingEntry.framesState
                if frameState.lastFrameQueued >= 0 {
                    requiredFramesToStart = min(requiredFramesToStart, frameState.lastFrameQueued - frameState.queued)
                }
                if used < requiredFramesToStart {
                    waitForBuffer = true
                }
            }
        }
        
        rendererContext.lock.unlock()
        
        var totalFramesCopied: UInt32 = 0
        if used > 0 && !waitForBuffer && state.contains(.running) && state != .paused {
            if end > start {
                let framesToCopy = min(inNumberFrames, used)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * framesToCopy
                
                if isMuted {
                    memset(bufferList.mBuffers.mData, 0, Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let buffermData = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData, buffermData + Int(start * frameSizeInBytes), Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                totalFramesCopied = framesToCopy
                
                rendererContext.lock.lock()
                rendererContext.bufferFramesStartIndex = (rendererContext.bufferFramesStartIndex + totalFramesCopied) % rendererContext.bufferTotalFrameCount
                rendererContext.bufferUsedFrameCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            } else {
                let frameToCopy = min(inNumberFrames, rendererContext.bufferTotalFrameCount - start)
                bufferList.mBuffers.mNumberChannels = 2
                bufferList.mBuffers.mDataByteSize = frameSizeInBytes * frameToCopy
                
                if isMuted {
                    memset(bufferList.mBuffers.mData, 0, Int(bufferList.mBuffers.mDataByteSize))
                } else {
                    if let buffermData = audioBuffer.mData {
                        memcpy(bufferList.mBuffers.mData, buffermData + Int(start * frameSizeInBytes), Int(bufferList.mBuffers.mDataByteSize))
                    }
                }
                
                var moreFramesToCopy: UInt32 = 0
                let delta = inNumberFrames - frameToCopy
                if delta > 0 {
                    moreFramesToCopy = min(delta, end)
                    bufferList.mBuffers.mNumberChannels = 2
                    bufferList.mBuffers.mDataByteSize += frameSizeInBytes * moreFramesToCopy
                    if let iomData = bufferList.mBuffers.mData {
                        if isMuted {
                            memset(iomData + Int(frameToCopy * frameSizeInBytes), 0, Int(frameSizeInBytes * moreFramesToCopy))
                        } else {
                            if let buffermData = audioBuffer.mData {
                                memcpy(iomData + Int(frameToCopy * frameSizeInBytes), buffermData, Int(frameSizeInBytes * moreFramesToCopy))
                            }
                        }
                    }
                }
                totalFramesCopied = frameToCopy + moreFramesToCopy

                rendererContext.lock.lock()
                rendererContext.bufferFramesStartIndex = (rendererContext.bufferFramesStartIndex + totalFramesCopied) % rendererContext.bufferTotalFrameCount
                rendererContext.bufferUsedFrameCount -= totalFramesCopied
                rendererContext.lock.unlock()
                
            }
            playerContext.setInternalState(to: .playing) { state -> Bool in
                state.contains(.running) && state != .paused
            }
            
        }
        
        if totalFramesCopied < inNumberFrames {
            let delta = inNumberFrames - totalFramesCopied
            if let mData = bufferList.mBuffers.mData {
                memset(mData + Int((totalFramesCopied * frameSizeInBytes)), 0, Int(delta * frameSizeInBytes))
            }
            if playerContext.currentPlayingEntry != nil || state == .waitingForDataAfterSeek || state == .waitingForData || state == .rebuffering {
                // buffering
                playerContext.setInternalState(to: .rebuffering) { state -> Bool in
                    state.contains(.running) && state != .paused
                }
            } else if state == .waitingForDataAfterSeek {
                // todo: implement this
            }
        }
        
        guard let currentPlayingEntry = entry else {
            return nil
        }
        currentPlayingEntry.lock.lock()
        
        var extraFramesPlayedNotAssigned: UInt32 = 0
        var framesPlayedForCurrent = totalFramesCopied

        if currentPlayingEntry.framesState.lastFrameQueued >= 0 {
            framesPlayedForCurrent = min(UInt32(currentPlayingEntry.framesState.lastFrameQueued - currentPlayingEntry.framesState.played), framesPlayedForCurrent)
        }
        
        currentPlayingEntry.framesState.played += Int(framesPlayedForCurrent)
        extraFramesPlayedNotAssigned = totalFramesCopied - framesPlayedForCurrent
        
        let lastFramePlayed = currentPlayingEntry.framesState.played == currentPlayingEntry.framesState.lastFrameQueued
        
        currentPlayingEntry.lock.unlock()
        
        if signal || lastFramePlayed {
            
            if lastFramePlayed && entry === playerContext.currentPlayingEntry {
                // todo call audio queue finished playing on audio player
                
                while extraFramesPlayedNotAssigned > 0 {
                    if let newEntry = playerContext.currentPlayingEntry {
                        var framesPlayedForCurrent = extraFramesPlayedNotAssigned
                        
                        let framesState = newEntry.framesState
                        if newEntry.framesState.lastFrameQueued > 0 {
                            framesPlayedForCurrent = min(UInt32(framesState.lastFrameQueued - framesState.played), framesPlayedForCurrent)
                        }
                        newEntry.lock.lock()
                        newEntry.framesState.played += Int(framesPlayedForCurrent)
                        
                        if framesState.played == framesState.lastFrameQueued {
                            newEntry.lock.unlock()
                            //
                            // todo call audio queue finished playing on audio player on newEntry
                        }
                        newEntry.lock.unlock()
                        
                        extraFramesPlayedNotAssigned -= framesPlayedForCurrent
                        
                    } else {
                        break
                    }
                }
            }
            
            self.audioSemaphore.signal()
        }
        
        let bytesPerFrames = UnitDescriptions.canonicalAudioStream.mBytesPerFrame
        let size = max(frameCount, bytesPerFrames * totalFramesCopied)

        rendererContext.inAudioBufferList[0].mBuffers.mData = rendererContext.outAudioBufferList[0].mBuffers.mData
        rendererContext.inAudioBufferList[0].mBuffers.mDataByteSize = size
        rendererContext.inAudioBufferList[0].mBuffers.mNumberChannels = UnitDescriptions.canonicalAudioStream.mChannelsPerFrame
        
        return UnsafePointer(rendererContext.inAudioBufferList)
    }
    
    private func configPlayerNode() {
        let playerRenderProcessor = self.playerRenderProcessor
        createAudioUnit(with: UnitDescriptions.output) { [weak self] result in
            switch result {
            case .success(let unit):
                self?.player = unit
            case .failure(let error):
                assertionFailure("couldn't create player unit: \(error)")
            }
        }

        guard let player = player else {
            raiseUnxpected(error: .audioSystemError)
            return
        }
        
        playerRenderProcessor.attachCallback(on: player)
    }
    
    private func attachAndConnectNodes(format: AVAudioFormat) {
        audioEngine.attach(equalizer)
        audioEngine.attach(rateNode)
        
        let eqFormat = equalizer.inputFormat(forBus: 0)
        audioEngine.connect(audioEngine.inputNode, to: rateNode, format: nil)
        audioEngine.connect(rateNode, to: equalizer, format: eqFormat)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format:  nil)
    }
    
    private func startEngine() throws {
        guard !isEngineRunning else { // sanity
            print("engine already running")
            return
        }
        try audioEngine.start()
        print("engine started 🛵")
    }
    
    private func startReadProcessFromSource() {
        audioReadSource.add { [weak self] in
            self?.processSource()
        }
        audioReadSource.resume()
    }
    
    private func stopReadProccessFromSource() {
        audioReadSource.removeHandler()
        audioReadSource.suspend()
    }
    
    private func startPlayer() {
        guard let player = player else { return }
        rendererContext.resetBuffers()
//        if isEngineRunning { return }
        let status = AudioOutputUnitStart(player.audioUnit)
        guard status == 0 else {
            raiseUnxpected(error: .audioSystemError)
            return
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
    }
    
    private func setCurrentReading(entry: AudioEntry?, startPlaying: Bool, shouldClearQueue: Bool) {
        guard let entry = entry else { return }
        print("Setting current reading entry to: \(entry)")
        
        if startPlaying {
            let count = Int(rendererContext.bufferTotalFrameCount * rendererContext.bufferFrameSizeInBytes)
            memset(rendererContext.outAudioBufferList[0].mBuffers.mData, 0, count)
        }
        
        if let fileStream = audioFileStream {
            AudioFileStreamClose(fileStream)
            audioFileStream = nil
        }
        
        if playerContext.currentReadingEntry != nil {
            playerContext.currentReadingEntry?.source.delegate = nil
            playerContext.currentReadingEntry?.source.removeFromQueue()
            playerContext.currentReadingEntry?.source.close()
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
            startPlayer()
        } else {
            entriesQueue.enqueue(item: entry, type: .buffering)
        }
    }
    
    private func processFinishPlaying(entry: AudioEntry?, with nextEntry: AudioEntry?) {
        guard entry == playerContext.currentPlayingEntry else { return }
        
        let isPlayingSameItemProbablySeek = playerContext.currentPlayingEntry == nextEntry
        
        let notifyDelegateEntryFinishedPlaying: (AudioEntry?, Bool) -> Void = { entry, probablySeek in
            if let entry = entry, !isPlayingSameItemProbablySeek {
                let entryId = entry.id
                let progressInFrames = entry.progressInFrames()
                let progress = Double(progressInFrames) / UnitDescriptions.canonicalAudioStream.mSampleRate
                let duration = entry.duration()
                
                asyncOnMain { [weak self] in
                    guard let self = self else { return }
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
            playerContext.entriesLock.around {
                playerContext.currentPlayingEntry = nil
            }
            notifyDelegateEntryFinishedPlaying(entry, isPlayingSameItemProbablySeek)
        }
    }
    
    /// Clears pending queues and informs the delegate
    private func clearQueue() {
        let pendingItems = self.entriesQueue.pendingEntriesId()
        self.entriesQueue.removeAll()
        if !pendingItems.isEmpty {
            asyncOnMain { [weak self] in
                guard let self = self else { return }
                self.delegate?.audioPlayerDidCancel(player: self, queuedItems: pendingItems)
            }
        }
    }
    
    private func raiseUnxpected(error: AudioPlayerErrorCode) {
        playerContext.internalState = .error
        // todo raise on main thread from playback thread
        delegate?.audioPlayerUnexpectedError(player: self, error: error)
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
                raiseUnxpected(error: .audioSystemError)
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
        
        guard let entry = playerContext.currentReadingEntry else {
            source.delegate = nil
            source.removeFromQueue()
            source.close()
            return
        }
        
        playerContext.currentPlayingEntry?.lock.lock()
        if let entry = playerContext.currentPlayingEntry {
            entry.framesState.lastFrameQueued = entry.framesState.queued
        }
        playerContext.currentPlayingEntry?.lock.unlock()
        entry.source.delegate = nil
        entry.source.removeFromQueue()
        entry.source.close()
        
        playerContext.entriesLock.lock()
        playerContext.currentReadingEntry = nil
        playerContext.entriesLock.unlock()
        processSource()
    }
    
    func metadataReceived(data: [String : String]) {
        self.delegate?.audioPlayerDidReadMetadata(player: self, metadata: data)
    }
    
}
