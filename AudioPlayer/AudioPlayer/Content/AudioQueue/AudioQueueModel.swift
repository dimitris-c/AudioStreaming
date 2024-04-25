//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import Foundation

@Observable
class AudioQueueModel {
    @ObservationIgnored
    private(set) var audioPlayerService: AudioPlayerService
    @ObservationIgnored
    private var displayLink: DisplayLink?


    init(audioPlayerService: AudioPlayerService) {
        self.audioPlayerService = audioPlayerService
    }
}
