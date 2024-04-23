//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct AudioPlayerView: View {
    @Environment(AppModel.self) var appModel

    @State var model: AudioPlayerModel

    @State var eqSheetIsShown: Bool = false
    @State var addNewAudioIsShown: Bool = false

    init(appModel: AppModel) {
        self._model = State(wrappedValue: AudioPlayerModel(audioPlayerService: appModel.audioPlayerService))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.audioTracks) { section in
                    Section {
                        ForEach(section.tracks) { track in
                            AudioTrackView(track: track) {
                                model.play(track)
                            }
                            .id(track.id)
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
            .onChange(of: model.audioTracks) { _, newValue in
                if let lastId = newValue.last?.tracks.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            AudioPlayerControls(viewModel: model)
                .background(
                    .ultraThinMaterial.shadow(
                        ShadowStyle.drop(color: .black.opacity(0.1), radius: 8, x: 0, y: -10)
                    )
                )
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("Audio Player")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    eqSheetIsShown.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                Button {
                    addNewAudioIsShown.toggle()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $eqSheetIsShown) {
            EqualizerView(appModel: appModel)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $addNewAudioIsShown) {
            AddNewAudioURLView(
                onAddNewUrl: { url in
                    model.addNewAudioTrack(url: url)
                }
            )
            .presentationDetents([.height(150)])
        }
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
            .tint(.mint)
            .padding(16)
            if let audioMetadata = viewModel.liveAudioMetadata, viewModel.isLiveAudioStreaming {
                Text("Now Playing: \(audioMetadata)")
                    .font(.caption)
                    .foregroundStyle(.black)
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
                .foregroundStyle(.black)
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
                    .foregroundStyle(.black)
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
    AudioPlayerView(appModel: AppModel())
}
