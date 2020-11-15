//
//  AppCoordinator.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit

final class AppCoordinator {
    private var navigationController: UINavigationController?

    private let playerService: AudioPlayerService

    init() {
        playerService = AudioPlayerService()
    }

    func start(window: UIWindow) {
        window.rootViewController = buildMain()
        window.makeKeyAndVisible()
    }

    private func buildMain() -> UINavigationController {
        let playlistItemsService = PlaylistItemsService(initialItemsProvider: provideInitialPlaylistItems)
        let viewModel = PlayerViewModel(playlistItemsService: playlistItemsService,
                                        playerService: playerService)
        let viewController = PlayerViewController(viewModel: viewModel,
                                                  controlsProvider: providePlayerControls)

        let navigationController = UINavigationController(rootViewController: viewController)
        self.navigationController = navigationController
        return navigationController
    }

    private func providePlayerControls() -> UIViewController {
        let viewModel = PlayerControlsViewModel(playerService: playerService)
        return PlayerControlsViewController(viewModel: viewModel)
    }
}
