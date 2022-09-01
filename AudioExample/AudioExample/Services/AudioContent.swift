//
//  AudioContent.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import Foundation

enum AudioContent: Int, CaseIterable {
    case offradio
    case enlefko
    case pepper966
    case kosmos
    case radiox
    case khruangbin
    case piano
    case remoteWave
    case local
    case localWave

    var title: String {
        switch self {
        case .offradio:
            return "Offradio (stream)"
        case .enlefko:
            return "Enlefko (stream)"
        case .pepper966:
            return "Pepper 96.6 (stream)"
        case .kosmos:
            return "Kosmos 93.6 (stream)"
        case .radiox:
            return "Radio X (stream)"
        case .khruangbin:
            return "Khruangbin (mp3 preview)"
        case .piano:
            return "Piano (mp3)"
        case .remoteWave:
            return "Sample remote (wave)"
        case .local:
            return "Jazzy Frenchy (local mp3)"
        case .localWave:
            return "Local file (local wave)"
        }
    }

    var subtitle: String? {
        switch self {
        case .offradio:
            return nil
        case .enlefko:
            return nil
        case .pepper966:
            return nil
        case .kosmos:
            return nil
        case .radiox:
            return nil
        case .khruangbin:
            return nil
        case .piano:
            return nil
        case .remoteWave:
            return nil
        case .local:
            return "Music by: bensound.com"
        case .localWave:
            return "Music by: bensound.com"
        }
    }

    var streamUrl: URL {
        switch self {
        case .enlefko:
            return URL(string: "https://stream.radiojar.com/srzwv225e3quv")!
        case .offradio:
            return URL(string: "https://s3.yesstreaming.net:17062/stream")!
        case .pepper966:
            return URL(string: "https://n04.radiojar.com/pepper.m4a?1662039818=&rj-tok=AAABgvlUaioALhdOXDt0mgajoA&rj-ttl=5")!
        case .kosmos:
            return URL(string: "https://radiostreaming.ert.gr/ert-kosmos")!
        case .radiox:
            return URL(string: "https://media-ssl.musicradio.com/RadioXLondon")!
        case .khruangbin:
            return URL(string: "https://p.scdn.co/mp3-preview/cab4b09c23ffc11774d879977131df9d150fcef4?cid=d8a5ed958d274c2e8ee717e6a4b0971d")!
        case .piano:
            return URL(string: "https://www.kozco.com/tech/piano2-CoolEdit.mp3")!
        case .local:
            let path = Bundle.main.path(forResource: "bensound-jazzyfrenchy", ofType: "mp3")!
            return URL(fileURLWithPath: path)
        case .localWave:
            let path = Bundle.main.path(forResource: "hipjazz", ofType: "wav")!
            return URL(fileURLWithPath: path)
        case .remoteWave:
            return URL(string: "https://file-examples.com/storage/fe183d9197630fb5c969255/2017/11/file_example_WAV_5MG.wav")!
        }
    }
}
