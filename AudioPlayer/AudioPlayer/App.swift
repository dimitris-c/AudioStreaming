//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import AudioStreaming
import SwiftUI

@main
struct AudioPlayerApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

func provideAudioPlayerService() -> AudioPlayerService {
    AudioPlayerService(
        audioPlayer: provideDefaultAudioPlayer()
    )
}

func provideDefaultAudioPlayer() -> AudioPlayer {
    AudioPlayer(
        configuration: .init(
            flushQueueOnSeek: false,
            enableLogs: true
        )
    )
}
