//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct AudioQueueView: View {
    @Environment(AppModel.self) var appModel

    @State var model: AudioQueueModel

    @State var eqSheetIsShown: Bool = false
    @State var addNewAudioIsShown: Bool = false

    init(appModel: AppModel) {
        self._model = State(wrappedValue: AudioQueueModel(audioPlayerService: appModel.audioPlayerService))
    }
    
    var body: some View {
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
        .safeAreaInset(edge: .bottom) {
            AudioPlayerControls(appModel: appModel, currentTrack: $model.currentTrack)
                .background(
                    .ultraThinMaterial.shadow(
                        ShadowStyle.drop(color: .black.opacity(0.1), radius: 8, x: 0, y: -10)
                    )
                )
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle("Audio Queue")
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

#Preview {
    AudioQueueView(appModel: AppModel())
}
