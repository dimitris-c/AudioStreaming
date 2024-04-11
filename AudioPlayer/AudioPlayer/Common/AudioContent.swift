//
//  AudioContent.swift
//  AudioPlayer
//
//  Created by Dimitris Chatzieleftheriou on 11/04/2024.
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
    case optimized
    case nonOptimized
    case remoteWave
    case local
    case localWave

    var title: String {
        switch self {
        case .offradio:
            return "Offradio"
        case .enlefko:
            return "Enlefko"
        case .pepper966:
            return "Pepper 96.6"
        case .kosmos:
            return "Kosmos 93.6"
        case .radiox:
            return "Radio X"
        case .khruangbin:
            return "Khruangbin"
        case .piano:
            return "Piano"
        case .remoteWave:
            return "Sample remote"
        case .local:
            return "Jazzy Frenchy"
        case .localWave:
            return "Local file"
        case .optimized:
            return "Jazze French"
        case .nonOptimized:
            return "Jazze French"
        }
    }

    var subtitle: String? {
        switch self {
        case .offradio:
            return "Stream"
        case .enlefko:
            return "Stream"
        case .pepper966:
            return "Stream"
        case .kosmos:
            return "Stream"
        case .radiox:
            return "Stream"
        case .khruangbin:
            return "Remote mp3"
        case .piano:
            return "Remote mp3"
        case .remoteWave:
            return "wave"
        case .local:
            return "Music by: bensound.com"
        case .localWave:
            return "Music by: bensound.com"
        case .optimized:
            return "Music by: bensound.com - m4a optimized"
        case .nonOptimized:
            return "Music by: bensound.com - m4a non-optimized"
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
        case .optimized:
            return URL(string: "https://github.com/dimitris-c/sample-audio/raw/main/bensound-jazzyfrenchy-optimized.m4a")!
        case .nonOptimized:
            return URL(string: "https://github.com/dimitris-c/sample-audio/raw/main/bensound-jazzyfrenchy.m4a")!
        case .local:
            let path = Bundle.main.path(forResource: "bensound-jazzyfrenchy", ofType: "mp3")!
            return URL(fileURLWithPath: path)
        case .localWave:
            let path = Bundle.main.path(forResource: "hipjazz", ofType: "wav")!
            return URL(fileURLWithPath: path)
        case .remoteWave:
            return URL(string: "https://file-examples.com/wp-content/storage/2017/11/file_example_WAV_5MG.wav")!
        }
    }
}
