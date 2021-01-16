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
    case local
    case podcast

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
        case .local:
            return "Local file (mp3)"
        case .podcast:
            return "Swift by Sundell. Ep. 50 (mp3)"
        }
    }

    var streamUrl: URL {
        switch self {
        case .enlefko:
            return URL(string: "https://stream.radiojar.com/srzwv225e3quv")!
        case .offradio:
            return URL(string: "https://s3.yesstreaming.net:17062/stream")!
        case .pepper966:
            return URL(string: "https://ample-09.radiojar.com/pepper.m4a?1593699983=&rj-tok=AAABcw_1KyMAIViq2XpI098ZSQ&rj-ttl=5")!
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
        case .podcast:
            return URL(string: "https://hwcdn.libsyn.com/p/f/6/e/f6e7cb785cf0f71f/SwiftBySundell50.mp3?c_id=45232967&cs_id=45232967&expiration=1605613140&hwt=f9ff0b2f758c3286cd75322e14ef7a23")!
        }
    }
}
