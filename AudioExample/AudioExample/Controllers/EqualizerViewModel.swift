//
//  EqualzerViewModel.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 15/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import AVFoundation

struct EQBand {
    let frequency: String
    let min: Float
    let max: Float
    let value: Float
}

final class EqualzerViewModel {
    private var bands: [EQBand] = []

    private let equalizerService: EqualizerService

    var equaliserIsOn: Bool {
        equalizerService.isActivated
    }

    init(equalizerService: EqualizerService) {
        self.equalizerService = equalizerService

        bands = equalizerService.bands.map { item in
            var measurement = item.frequency
            var frequency = String(Int(measurement))
            if item.frequency >= 1000 {
                measurement = item.frequency / 1000
                frequency = "\(String(Int(measurement)))K"
            }
            return EQBand(frequency: frequency, min: -12, max: 12, value: item.gain)
        }
    }

    func enableEq(_ enable: Bool) {
        if enable {
            equalizerService.activate()
        } else {
            equalizerService.deactivate()
        }
    }

    func resetEq(updateSliders: (_ value: Float) -> Void) {
        equalizerService.reset()
        updateSliders(0)
    }

    func update(gain: Float, for index: Int) {
        equalizerService.update(gain: gain, for: index)
    }

    func numberOfBands() -> Int {
        equalizerService.bands.count
    }

    func band(at index: Int) -> EQBand? {
        guard index < numberOfBands() else { return nil }
        return bands[index]
    }
}
