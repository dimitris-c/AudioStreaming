//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct AudioPlayerView: View {

    @State var model = AudioPlayerModel()

    var body: some View {
        List {
            ForEach(model.audioTracks) { section in
                Section {
                    ForEach(section.tracks) { track in
                        AudioTrackView(track: track) {
                            model.play(track)
                        }
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            AudioPlayerControls(viewModel: model)
                .background(Color.mint)
        }
        .navigationTitle("Audio Player")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AudioPlayerControls: View {
    @Bindable var viewModel: AudioPlayerModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button(action: { viewModel.playPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .imageScale(.small)
                }
                .contentTransition(.symbolEffect(.replace))
                Button(action: { viewModel.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.title)
                        .imageScale(.small)
                }
                .padding(.leading, 8)
                Spacer()
                Button(action: { viewModel.mute() }) {
                    Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.title)
                        .imageScale(.small)
                }
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
            }
            .tint(.white)
            .padding(16)
            if let audioMetadata = viewModel.liveAudioMetadata, viewModel.isLiveAudioStreaming {
                Text("Now Playing: \(audioMetadata)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
            }
            Divider()
            VStack {
                Slider(
                    value: $viewModel.currentTime,
                    in: 0...(viewModel.totalTime ?? 1.0),
                    onEditingChanged: { scrubStarted in
                        if scrubStarted {
                            viewModel.scrubState = .started
                        } else {
                            viewModel.scrubState = .ended(viewModel.currentTime)
                        }
                    }
                )
                .disabled(viewModel.totalTime == nil)
                HStack {
                    Text(viewModel.formattedCurrentTime ?? "--:--")
                    Spacer()
                    Text(viewModel.formattedTotalTime ?? "")
                }
                .foregroundStyle(.white)
                .font(.caption)
                .fontWeight(.medium)
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
            Divider()
            VStack(alignment: .leading) {
                Text("Playback Rate: \(String(format: "%0.1f", viewModel.playbackRate))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
                Slider(value: $viewModel.playbackRate, in: 1.0...4.0, step: 0.2)
                    .onChange(of: viewModel.playbackRate) { _, new in
                        viewModel.update(rate: Float(new))
                    }
            }
            .padding(.bottom, 8)
            .padding(.horizontal, 16)
        }
    }
}

#Preview {
    AudioPlayerView(model: AudioPlayerModel())
}
