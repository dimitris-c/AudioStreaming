//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import Foundation
import AudioStreaming

struct AudioPlaylist: Identifiable {
    var id: String { title }
    let title: String
    let tracks: [AudioTrack]
}

@Observable
public class AudioPlayerModel {
    @ObservationIgnored
    var audioPlayerService: AudioPlayerService

    var audioTracks: [AudioPlaylist] = []

    var isLiveAudioStreaming: Bool {
        totalTime == 0
    }

    var isPlaying: Bool = false
    var isMuted: Bool = false

    var playbackRate: Double = 0.0

    var currentTime: Double = 0.0
    var totalTime: Double?

    var currentTrack: AudioTrack?

    init(audioTracksProvider: () -> [AudioPlaylist] = audioTracksProvider, audioPlayerService: () -> AudioPlayerService = provideAudioPlayerService) {
        self.audioPlayerService = audioPlayerService()
        self.audioTracks = audioTracksProvider()

        self.audioPlayerService.delegate = self
    }

    func mute() {
        isMuted.toggle()
        audioPlayerService.toggleMute()
    }

    func playPause() {
        isPlaying.toggle()
        if audioPlayerService.state == .playing {
            audioPlayerService.pause()
        } else {
            audioPlayerService.resume()
        }
    }

    func stop() {
        isPlaying = false
        audioPlayerService.stop()
        currentTrack?.status = .idle
        currentTrack = nil
    }

    func play(_ track: AudioTrack) {
        if track != currentTrack {
            currentTrack?.status = .idle
            audioPlayerService.play(url: track.url)
            currentTrack = track
        }
    }
}

extension AudioPlayerModel: AudioPlayerServiceDelegate {
    func didStartPlaying(id: AudioEntryId) {
    }

    func didStopPlaying(id: AudioEntryId, reason: AudioPlayerStopReason) {

    }

    func statusChanged(status: AudioStreaming.AudioPlayerState) {
        switch status {
        case .bufferring:
            currentTrack?.status = .buffering
            isPlaying = false
        case .error:
            currentTrack?.status = .error
            isPlaying = false
        case .playing:
            currentTrack?.status = .playing
            isPlaying = true
        case .paused:
            currentTrack?.status = .paused
            isPlaying = false
        case .stopped:
            currentTrack?.status = .idle
            isPlaying = false
        default:
            currentTrack?.status = .idle
        }
    }

    func errorOccurred(error: AudioStreaming.AudioPlayerError) {

    }

    func metadataReceived(metadata: [String : String]) {

    }
}

func audioTracksProvider() -> [AudioPlaylist] {
    let radioTracks: [AudioContent] = [.offradio, .enlefko, .pepper966, .kosmos, .radiox]
    let audioTracks: [AudioContent] = [.khruangbin, .piano, .optimized, .nonOptimized, .remoteWave, .local, .localWave]

    return [
        AudioPlaylist(title: "Radio", tracks: radioTracks.map { AudioTrack.init(from: $0) }),
        AudioPlaylist(title: "Tracks", tracks: audioTracks.map { AudioTrack.init(from:$0) })
    ]
}
