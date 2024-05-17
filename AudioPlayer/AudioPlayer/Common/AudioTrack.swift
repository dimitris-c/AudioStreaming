//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//


import SwiftUI

enum AudioTrackStatus {
    case playing
    case paused
    case buffering
    case error
    case idle

    var isPlaying: Bool {
        self == .playing || self == .paused
    }

    var isError: Bool {
        self == .error
    }
}

@Observable
public class AudioTrack: Identifiable, Equatable {
    public static func == (lhs: AudioTrack, rhs: AudioTrack) -> Bool {
        lhs.id == rhs.id
    }

    public var id: String {
        url.absoluteString
    }
    let title: String
    let subtitle: String?
    let url: URL

    var status: AudioTrackStatus

    private let content: AudioContent

    init(from content: AudioContent, status: AudioTrackStatus = .idle) {
        self.title = content.title
        self.subtitle = content.subtitle
        self.status = status
        self.url = content.streamUrl
        self.content = content
    }
}


struct AudioTrackView: View {
    @Bindable var track: AudioTrack

    private let action: () -> Void

    init(track: AudioTrack, action: @escaping () -> Void = {}) {
        self.track = track
        self.action = action
    }

    var body: some View {
        Button(action: action, label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(track.title)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundStyle(.black)
                        .padding(.top, 8)
                        .padding(.bottom, track.subtitle == nil ? 8 : 0)
                    if let subtitle = track.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(Color.gray)
                    }
                }
                Spacer()
                status
            }
        })
    }

    @ViewBuilder var status: some View {
        if track.status == .error {
            Image(systemName: "exclamationmark.circle")
                .font(.headline)
                .foregroundStyle(.red)
        } else {
            if track.status.isPlaying {
                Image(systemName: track.status == .playing ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .foregroundStyle(.mint)
            } else if track.status == .buffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(alignment: .center)
                    .scaleEffect(0.7)
            }
        }
    }
}

#Preview {
    List {
        AudioTrackView(
            track: AudioTrack(from: .enlefko)
        )
        AudioTrackView(
            track: AudioTrack(from: .enlefko, status: .playing)
        )
        AudioTrackView(
            track:  AudioTrack(from: .enlefko, status: .paused)
        )
        AudioTrackView(
            track:  AudioTrack(from: .enlefko, status: .error)
        )
    }
}
