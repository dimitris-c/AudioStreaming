//
//  DetailView.swift
//  AudioPlayer
//
//  Created by Dimitris Chatzieleftheriou on 10/04/2024.
//

import SwiftUI

struct DetailView: View {
    @Binding var selection: MainContent?

    var body: some View {
        if let selection {
            switch selection {
            case .audioPlayer:
                AudioPlayerView()
            case .audioQueue:
                Text("Audio Queue")
            }
        }
    }
}
