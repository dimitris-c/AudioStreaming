//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import AVFoundation

final class EqualizerService {
    private let playerService: AudioPlayerService
    private let _freqs = [60, 150, 400, 1000, 2400, 15000]
    private let eqUnit: AVAudioUnitEQ

    var bands: [AVAudioUnitEQFilterParameters] {
        eqUnit.bands
    }

    private(set) var isActivated: Bool = false

    init(playerService: AudioPlayerService) {
        self.playerService = playerService

        eqUnit = AVAudioUnitEQ(numberOfBands: _freqs.count)
        for i in 0 ..< _freqs.count {
            eqUnit.bands[i].bypass = false
            eqUnit.bands[i].filterType = .parametric
            eqUnit.bands[i].frequency = Float(_freqs[i])
            eqUnit.bands[i].bandwidth = 0.5
            eqUnit.bands[i].gain = 0
        }
    }

    func update(gain: Float, for index: Int) {
        eqUnit.bands[index].gain = gain
    }

    func reset() {
        eqUnit.bands.forEach { $0.gain = 0 }
    }

    func activate() {
        isActivated = true
        playerService.add(eqUnit)
    }

    func deactivate() {
        isActivated = false
        playerService.remove(eqUnit)
    }
}
