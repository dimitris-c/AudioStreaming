//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

#if os(iOS)
import UIKit
#else
import AppKit
#endif

import Foundation
import AudioStreaming

struct AudioPlaylist: Equatable, Identifiable {
    var id: String { title }
    let title: String
    var tracks: [AudioTrack]
}

@Observable
public class AudioPlayerModel {
    @ObservationIgnored
    private(set) var audioPlayerService: AudioPlayerService

    var audioTracks: [AudioPlaylist] = []

    var currentTrack: AudioTrack?

    init(audioTracksProvider: () -> [AudioPlaylist] = audioTracksProvider, audioPlayerService: AudioPlayerService) {
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

private let radioTracks: [AudioContent] = [.offradio, .enlefko, .pepper966, .kosmos, .kosmosJazz, .radiox]
private let audioTracks: [AudioContent] = [.khruangbin, .piano, .optimized, .nonOptimized, .remoteWave, .local, .localWave]

func audioTracksProvider() -> [AudioPlaylist] {
    [
        AudioPlaylist(title: "Radio", tracks: radioTracks.map { AudioTrack.init(from: $0) }),
        AudioPlaylist(title: "Tracks", tracks: audioTracks.map { AudioTrack.init(from:$0) })
    ]
}

func audioQueueTrackProvider() -> [AudioPlaylist] {
    [
        AudioPlaylist(title: "Tracks", tracks: audioTracks.map { AudioTrack.init(from:$0) })
    ]
}
