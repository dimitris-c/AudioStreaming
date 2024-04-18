//
//  DetailView.swift
//  AudioPlayer
//
//  Created by Dimitris Chatzieleftheriou on 10/04/2024.
//

import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) var appModel

    var selection: NavigationContent

    var body: some View {
        switch selection {
        case .audioPlayer:
            AudioPlayerView(appModel: appModel)
        case .audioQueue:
            Text("Audio Queue")
        }
    }
}
