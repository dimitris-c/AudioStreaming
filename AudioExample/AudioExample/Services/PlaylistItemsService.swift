//
//  PlaylistItemsService.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import Foundation

struct PlaylistItem: Equatable {
    enum Status: Equatable {
        case playing
        case paused
        case buffering
        case stopped
    }

    let url: URL
    let name: String
    let status: Status
    let queues: Bool

    init(content: AudioContent, queues: Bool) {
        name = content.title
        url = content.streamUrl
        status = .stopped
        self.queues = queues
    }

    init(url: URL, name: String, status: Status, queues: Bool) {
        self.url = url
        self.name = name
        self.status = status
        self.queues = queues
    }
}

final class PlaylistItemsService {
    private var items: [PlaylistItem] = []

    var itemsCount: Int {
        items.count
    }

    let protectedItemCount: Int

    init(initialItemsProvider: () -> [PlaylistItem]) {
        items = initialItemsProvider()
        protectedItemCount = items.count
    }

    func item(at index: Int) -> PlaylistItem? {
        guard index < items.count else { return nil }
        return items[index]
    }

    func index(for item: PlaylistItem) -> Int? {
        items.firstIndex(of: item)
    }

    func add(item: PlaylistItem) {
        items.append(item)
    }

    func remove(item: PlaylistItem) {
        if let index = items.firstIndex(of: item) {
            items.remove(at: index)
        }
    }

    func setStatus(for index: Int, status: PlaylistItem.Status) {
        guard let item = item(at: index) else {
            return
        }
        items[index] = PlaylistItem(url: item.url, name: item.name, status: status, queues: item.queues)
    }
}

func provideInitialPlaylistItems() -> [PlaylistItem] {
    let allCases = AudioContent.allCases
    let casesForQueueing: [AudioContent] = [.piano, .local, .khruangbin]
    let allItems = allCases.map { PlaylistItem(content: $0, queues: false) }
    let casesForQueuingItems = casesForQueueing.map { PlaylistItem(content: $0, queues: true) }
    return allItems + casesForQueuingItems
}
