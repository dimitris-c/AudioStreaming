//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import AudioStreaming
import AVFoundation

protocol AudioPlayerServiceDelegate: AnyObject {
    func didStartPlaying(id: AudioEntryId)
    func didStopPlaying(id: AudioEntryId, reason: AudioPlayerStopReason)
    func statusChanged(status: AudioPlayerState)
    func errorOccurred(error: AudioPlayerError)
    func metadataReceived(metadata: [String: String])
}

final class AudioPlayerService {
    weak var delegate: AudioPlayerServiceDelegate?

    private var player: AudioPlayer
    private var audioSystemResetObserver: Any?

    var duration: Double {
        player.duration
    }

    var progress: Double {
        player.progress
    }

    var isMuted: Bool {
        player.muted
    }

    var rate: Float {
        player.rate
    }

    var state: AudioPlayerState {
        player.state
    }

    var statusChangedNotifier = Notifier<AudioPlayerState>()
    var metadataReceivedNotifier = Notifier<[String: String]>()
    var playingStartedStopped = Notifier<(started: Bool, AudioEntryId, AudioPlayerStopReason?)>()

    private let audioPlayerProvider: () -> AudioPlayer

    init(audioPlayerProvider: @escaping () -> AudioPlayer) {
        self.audioPlayerProvider = audioPlayerProvider
        player = audioPlayerProvider()
        player.delegate = self

        configureAudioSession()
        registerSessionEvents()
    }

    func play(url: URL) {
        activateAudioSession()
        player.play(url: url)
    }

    func queue(url: URL) {
        activateAudioSession()
        player.queue(url: url)
    }

    func stop() {
        player.stop()
        deactivateAudioSession()
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.resume()
    }

    func toggleMute() {
        player.muted = !player.muted
    }

    func update(rate: Float) {
        player.rate = rate
    }

    func update(volume: Float) {
        player.volume = volume
    }

    func add(_ node: AVAudioNode) {
        player.attach(node: node)
    }

    func remove(_ node: AVAudioNode) {
        player.detach(node: node)
    }

    func toggle() {
        if player.state == .paused {
            player.resume()
        } else {
            player.pause()
        }
    }

    func seek(at time: Double) {
        player.seek(to: time)
    }

    private func recreatePlayer() {
        player = audioPlayerProvider()
        player.delegate = self
    }

    private func registerSessionEvents() {
        // Note that a real app might need to observer other AVAudioSession notifications as well
#if os(iOS)
        audioSystemResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [unowned self] _ in
            self.configureAudioSession()
            self.recreatePlayer()
        }
#endif
    }

    private func configureAudioSession() {
#if os(iOS)
        do {
            print("AudioSession category is AVAudioSessionCategoryPlayback")
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.1)
        } catch let error as NSError {
            print("Couldn't setup audio session category to Playback \(error.localizedDescription)")
        }
#endif
    }

    private func activateAudioSession() {
#if os(iOS)
        do {
            print("AudioSession is active")
            try AVAudioSession.sharedInstance().setActive(true, options: [])

        } catch let error as NSError {
            print("Couldn't set audio session to active: \(error.localizedDescription)")
        }
#endif
    }

    private func deactivateAudioSession() {
#if os(iOS)
        do {
            print("AudioSession is deactivated")
            try AVAudioSession.sharedInstance().setActive(false)
        } catch let error as NSError {
            print("Couldn't deactivate audio session: \(error.localizedDescription)")
        }
#endif
    }
}

extension AudioPlayerService: AudioPlayerDelegate {
    func audioPlayerDidStartPlaying(player _: AudioPlayer, with id: AudioEntryId) {
        print("audioPlayerDidStartPlaying entryId: \(id)")
        delegate?.didStartPlaying(id: id)
        Task { await playingStartedStopped.send((true, id, nil)) }
    }

    func audioPlayerDidFinishBuffering(player _: AudioPlayer, with _: AudioEntryId) {}

    func audioPlayerStateChanged(player _: AudioPlayer, with newState: AudioPlayerState, previous _: AudioPlayerState) {
        print("audioPlayerDidStartPlaying newState: \(newState)")
        Task { await statusChangedNotifier.send(newState) }
        delegate?.statusChanged(status: newState)
    }

    func audioPlayerDidFinishPlaying(player _: AudioPlayer,
                                     entryId id: AudioEntryId,
                                     stopReason reason: AudioPlayerStopReason,
                                     progress _: Double,
                                     duration _: Double)
    {
        print("audioPlayerDidFinishPlaying entryId: \(id), reason: \(reason)")
        Task { await playingStartedStopped.send((false, id, reason)) }
        delegate?.didStopPlaying(id: id, reason: reason)
    }

    func audioPlayerUnexpectedError(player _: AudioPlayer, error: AudioPlayerError) {
        delegate?.errorOccurred(error: error)
    }

    func audioPlayerDidCancel(player _: AudioPlayer, queuedItems _: [AudioEntryId]) {}

    func audioPlayerDidReadMetadata(player _: AudioPlayer, metadata: [String: String]) {
        Task { await metadataReceivedNotifier.send(metadata) }
        delegate?.metadataReceived(metadata: metadata)
    }
}
