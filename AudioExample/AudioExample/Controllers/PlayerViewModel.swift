//
//  PlayerViewModel.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import AudioStreaming
import Foundation

enum ReloadAction {
    case all
    case item(IndexPath)
}

final class PlayerViewModel {
    private let playerService: AudioPlayerService
    private let playlistItemsService: PlaylistItemsService

    private let routeTo: (AppCoordinator.Route) -> Void
    private var currentPlayingItemIndex: Int?

    var reloadContent: ((ReloadAction) -> Void)?

    init(playlistItemsService: PlaylistItemsService,
         playerService: AudioPlayerService,
         routeTo: @escaping (AppCoordinator.Route) -> Void)
    {
        self.playlistItemsService = playlistItemsService
        self.playerService = playerService
        self.routeTo = routeTo
        self.playerService.delegate.add(delegate: self)
    }

    func showEqualizer() {
        routeTo(.equalizer)
    }

    var itemsCount: Int {
        playlistItemsService.itemsCount
    }

    func add(urlString: String) {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let result = detector.firstMatch(in: urlString, options: [], range: NSRange(location: 0, length: urlString.utf16.count))
        guard let url = URL(string: urlString), result != nil else {
            print("malformed url error")
            return
        }
        playlistItemsService.add(item: PlaylistItem(url: url, name: urlString, status: .stopped, queues: false))
        reloadContent?(.all)
    }

    func item(at indexPath: IndexPath) -> PlaylistItem? {
        playlistItemsService.item(at: indexPath.row)
    }

    func playItem(at indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        if item.queues {
            playerService.queue(url: item.url)
            if currentPlayingItemIndex == nil {
                currentPlayingItemIndex = indexPath.row
            }
        } else {
            if let index = currentPlayingItemIndex {
                playlistItemsService.setStatus(for: index, status: .stopped)
                reloadContent?(.item(IndexPath(row: index, section: 0)))
                currentPlayingItemIndex = nil
            }
            playerService.play(url: item.url)
            currentPlayingItemIndex = indexPath.row
        }
    }
}

extension PlayerViewModel: AudioPlayerServiceDelegate {
    func statusChanged(status: AudioPlayerState) {
        guard let item = currentPlayingItemIndex else { return }

        switch status {
        case .bufferring:
            playlistItemsService.setStatus(for: item, status: .buffering)
            reloadContent?(.item(IndexPath(item: item, section: 0)))
        case .playing:
            playlistItemsService.setStatus(for: item, status: .playing)
            reloadContent?(.item(IndexPath(item: item, section: 0)))
        case .paused:
            playlistItemsService.setStatus(for: item, status: .paused)
            reloadContent?(.item(IndexPath(item: item, section: 0)))
        case .stopped:
            playlistItemsService.setStatus(for: item, status: .stopped)
            reloadContent?(.item(IndexPath(item: item, section: 0)))
        default:
            break
        }
    }

    func errorOccurred(error _: AudioPlayerError) {
        currentPlayingItemIndex = nil
    }

    func metadataReceived(metadata _: [String: String]) {}
    func didStopPlaying() {}

    func didStartPlaying() {}
}
