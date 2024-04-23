//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import UIKit
import Foundation
import AudioStreaming

struct AudioPlaylist: Equatable, Identifiable {
    var id: String { title }
    let title: String
    var tracks: [AudioTrack]
}

enum ScrubState: Equatable {
    case idle
    case started
    case ended(Double)
}

@Observable
public class AudioPlayerModel {
    @ObservationIgnored
    private(set) var audioPlayerService: AudioPlayerService
    @ObservationIgnored
    private var displayLink: DisplayLink?

    var audioTracks: [AudioPlaylist] = []

    var isLiveAudioStreaming: Bool {
        totalTime == 0
    }

    var liveAudioMetadata: String?

    var isPlaying: Bool = false
    var isMuted: Bool = false

    var playbackRate: Double = 0.0

    var currentTime: Double = 0
    var totalTime: Double?

    var scrubState: ScrubState = .idle

    var formattedCurrentTime: String?
    var formattedTotalTime: String?

    var currentTrack: AudioTrack?

    init(audioTracksProvider: () -> [AudioPlaylist] = audioTracksProvider, audioPlayerService: AudioPlayerService) {
        self.audioPlayerService = audioPlayerService
        self.audioTracks = audioTracksProvider()

        self.audioPlayerService.delegate = self
    }

    deinit {
        audioPlayerService.stop()
        displayLink?.deactivate()
        displayLink = nil
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

    func mute() {
        isMuted.toggle()
        audioPlayerService.toggleMute()
    }

    func playPause() {
        if audioPlayerService.state == .playing {
            audioPlayerService.pause()
        } else {
            audioPlayerService.resume()
        }
    }

    func update(rate: Float) {
        let rate = round(rate / 0.2) * 0.2
        audioPlayerService.update(rate: rate)
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

    func onTick() {
        let duration = audioPlayerService.duration
        let progress = audioPlayerService.progress
        if duration > 0 {
            let elapsed = Int(progress)
            let remaining = Int(duration - progress)
            totalTime = duration
            switch scrubState {
            case .idle:
                currentTime = progress
            case .started:
                break
            case .ended(let seekTime):
                currentTime = seekTime
                if audioPlayerService.duration > 0 {
                    audioPlayerService.seek(at: seekTime)
                }
                scrubState = .idle
            }
            formattedCurrentTime = timeFrom(seconds: Int(elapsed))
            formattedTotalTime = timeFrom(seconds: remaining)
        } else {
            let elapsed = Int(progress)
            formattedCurrentTime = timeFrom(seconds: Int(elapsed))
            if formattedTotalTime != nil {
                formattedTotalTime = nil
            }
        }
    }

    func resetLabels() {
        currentTime = 0
        totalTime = 0
        formattedCurrentTime = nil
        formattedTotalTime = nil
    }

    private func timeFrom(seconds: Int) -> String {
        let correctSeconds = seconds % 60
        let minutes = (seconds / 60) % 60
        let hours = seconds / 3600

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, correctSeconds)
        }
        return String(format: "%02d:%02d", minutes, correctSeconds)
    }
}

extension AudioPlayerModel: AudioPlayerServiceDelegate {
    func didStartPlaying(id: AudioEntryId) {
        self.displayLink = DisplayLink(onTick: { [weak self] _ in
            self?.onTick()
        })
        displayLink?.activate()
    }

    func didStopPlaying(id: AudioEntryId, reason: AudioPlayerStopReason) {
        resetLabels()
        liveAudioMetadata = nil
        playbackRate = 1.0
        displayLink?.deactivate()
    }

    func statusChanged(status: AudioStreaming.AudioPlayerState) {
        isPlaying = status == .playing
        displayLink?.isPaused = !isPlaying
        switch status {
        case .bufferring:
            currentTrack?.status = .buffering
        case .error:
            currentTrack?.status = .error
            currentTrack = nil
        case .playing:
            currentTrack?.status = .playing
        case .paused:
            currentTrack?.status = .paused
        case .stopped:
            currentTrack?.status = .idle
        default:
            currentTrack?.status = .idle
        }
    }

    func errorOccurred(error: AudioStreaming.AudioPlayerError) {

    }

    func metadataReceived(metadata: [String : String]) {
        guard !metadata.isEmpty else { return }
        if let title = metadata["StreamTitle"] {
            liveAudioMetadata = title.isEmpty ? "-" : title
        } else {
            liveAudioMetadata = nil
        }
    }
}

func audioTracksProvider() -> [AudioPlaylist] {
    let radioTracks: [AudioContent] = [.offradio, .enlefko, .pepper966, .kosmos, .kosmosJazz, .radiox]
    let audioTracks: [AudioContent] = [.khruangbin, .piano, .optimized, .nonOptimized, .remoteWave, .local, .localWave]

    return [
        AudioPlaylist(title: "Radio", tracks: radioTracks.map { AudioTrack.init(from: $0) }),
        AudioPlaylist(title: "Tracks", tracks: audioTracks.map { AudioTrack.init(from:$0) })
    ]
}
