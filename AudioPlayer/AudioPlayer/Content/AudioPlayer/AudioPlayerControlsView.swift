//
//  Created by Dimitris Chatzieleftheriou on 26/04/2024.
//

import AVFoundation
import SwiftUI

struct AudioPlayerControls: View {
    @State var model: Model
    @Binding var currentTrack: AudioTrack?

    init(appModel: AppModel, currentTrack: Binding<AudioTrack?>) {
        self._model = State(wrappedValue: Model(audioPlayerService: appModel.audioPlayerService))
        self._currentTrack = currentTrack
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button(action: { model.playPause() }) {
                    Image(systemName: model.isPlaying ? "pause" : "play")
                        .symbolVariant(.fill)
                        .font(.title)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .contentTransition(.symbolEffect(.replace))
                Button(action: {
                    model.stop()
                    currentTrack = nil
                }) {
                    Image(systemName: "stop")
                        .symbolVariant(.fill)
                        .font(.title)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                Spacer()
                HStack {
                    Slider(value: $model.volume)
                        .frame(width: 80)
                        .onChange(of: model.volume) { _, newValue in
                            model.update(volume: newValue)
                        }
                    Button(action: { model.mute() }) {
                        Image(systemName: model.iconForVolume)
                            .symbolVariant(model.isMuted || model.volume == 0 ? .slash.fill : .fill)
                            .foregroundStyle(.teal, .gray)
                            .font(.title.monospaced())
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                }
            }
            .tint(.mint)
            .padding(16)
            if let audioMetadata = model.liveAudioMetadata, model.isLiveAudioStreaming {
                Text("Now Playing: \(audioMetadata)")
                    .font(.caption)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
            }
            Divider()
            VStack {
                Slider(
                    value: $model.currentTime,
                    in: 0...(model.totalTime ?? 1.0),
                    onEditingChanged: { scrubStarted in
                        if scrubStarted {
                            model.scrubState = .started
                        } else {
                            model.scrubState = .ended(model.currentTime)
                        }
                    }
                )
                .disabled(model.totalTime == nil)
                HStack {
                    Text(model.formattedCurrentTime ?? "--:--")
                    Spacer()
                    Text(model.formattedTotalTime ?? "")
                }
                .foregroundStyle(.black)
                .font(.caption)
                .fontWeight(.medium)
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
            Divider()
            VStack(alignment: .leading) {
                Text("Playback Rate: \(String(format: "%0.1f", model.playbackRate))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.black)
                Slider(value: $model.playbackRate, in: 1.0...4.0, step: 0.2)
                    .onChange(of: model.playbackRate) { _, new in
                        model.update(rate: Float(new))
                    }
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
        }
        .onChange(of: currentTrack) { oldValue, newValue in
            if let track = newValue {
                model.play(track)
            }
        }
    }
}

enum ScrubState: Equatable {
    case idle
    case started
    case ended(Double)
}

extension AudioPlayerControls {
    @Observable
    final class Model {
        @ObservationIgnored
        private(set) var audioPlayerService: AudioPlayerService
        @ObservationIgnored
        private var displayLink: DisplayLink?

        var isLiveAudioStreaming: Bool {
            totalTime == 0
        }

        var liveAudioMetadata: String?

        var isPlaying: Bool = false
        var isMuted: Bool = false

        var volume: Float = 0.5

        var playbackRate: Double = 0.0

        var currentTime: Double = 0
        var totalTime: Double?

        var scrubState: ScrubState = .idle

        var formattedCurrentTime: String?
        var formattedTotalTime: String?

        var currentTrack: AudioTrack?

        var iconForVolume: String {
            if isMuted || volume == 0 {
                return "speaker"
            }
            if volume < 0.4 {
                return "speaker.wave.1"
            } else if volume < 0.8 {
                return "speaker.wave.2"
            } else {
                return "speaker.wave.3"
            }
        }

        init(audioPlayerService: AudioPlayerService) {
            self.audioPlayerService = audioPlayerService

            registerObservations()
        }

        deinit {
            displayLink?.deactivate()
            displayLink = nil
        }

        func registerObservations() {
            Task { @MainActor in
                for await status in await audioPlayerService.statusChangedNotifier.values() {
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
            }

            Task { @MainActor in
                for await metadata in await audioPlayerService.metadataReceivedNotifier.values() {
                    guard !metadata.isEmpty else { break }
                    if let title = metadata["StreamTitle"] {
                        liveAudioMetadata = title.isEmpty ? "-" : title
                    } else {
                        liveAudioMetadata = nil
                    }
                }
            }

            Task { @MainActor in
                for await startStopped in await audioPlayerService.playingStartedStopped.values() {
                    if startStopped.started {
                        self.didStartPlaying()
                    } else {
                        self.didStopPlaying()
                    }
                }
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

        func update(volume: Float) {
            audioPlayerService.update(volume: volume)
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

        private func didStartPlaying() {
            self.displayLink = DisplayLink(onTick: { [weak self] _ in
                self?.onTick()
            })
            displayLink?.activate()
        }

        private func didStopPlaying() {
            resetLabels()
            liveAudioMetadata = nil
            playbackRate = 1.0
            displayLink?.deactivate()
        }
    }

}
