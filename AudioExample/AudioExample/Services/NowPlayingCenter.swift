//
//  NowPlayingCenter.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 15/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import MediaPlayer

final class NowPlayingCenter {
    private let infoCenter: MPNowPlayingInfoCenter

    init(infoCenter: MPNowPlayingInfoCenter = .default()) {
        self.infoCenter = infoCenter
    }

    func change(item: PlaylistItem, isLiveStream: Bool) {
        var nowPlayingInfo = infoCenter.nowPlayingInfo ?? [String: Any]()

        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = isLiveStream
        nowPlayingInfo[MPMediaItemPropertyArtist] = item.name

        infoCenter.nowPlayingInfo = nowPlayingInfo
    }

    func update(with metadata: [String: String], with item: PlaylistItem) {
        var nowPlayingInfo = infoCenter.nowPlayingInfo ?? [String: Any]()

        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata["StreamTitle"]
        nowPlayingInfo[MPMediaItemPropertyArtist] = item.name

        infoCenter.nowPlayingInfo = nowPlayingInfo
    }
}
