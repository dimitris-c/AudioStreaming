//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import Foundation

@Observable
class AudioQueueModel {
    @ObservationIgnored
    private(set) var audioPlayerService: AudioPlayerService
    @ObservationIgnored
    private var displayLink: DisplayLink?

    var audioTracks: [AudioPlaylist] = []

    var currentTrack: AudioTrack?

    init(audioTracksProvider: () -> [AudioPlaylist] = audioQueueTrackProvider, audioPlayerService: AudioPlayerService) {
        self.audioPlayerService = audioPlayerService
        self.audioTracks = audioTracksProvider()
    }

    deinit {
        audioPlayerService.stop()
    }

    func addNewAudioTrack(url: URL) {
        let customIndex = audioTracks.firstIndex(where: { $0.id == "Custom" })
        let audioTrack = AudioTrack(from: .custom(url.absoluteString), status: .idle)
        let playlist = AudioPlaylist(title: "Custom", tracks: [audioTrack])
        if let customIndex {
            let tracks = audioTracks[customIndex].tracks
            if !tracks.contains(audioTrack) {
                audioTracks[customIndex].tracks.append(audioTrack)
            }
        } else {
            audioTracks.append(playlist)
        }
    }

    func play(_ track: AudioTrack) {
        if track != currentTrack {
            currentTrack = track
        }
    }
}
