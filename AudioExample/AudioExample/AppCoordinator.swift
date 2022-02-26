//
//  AppCoordinator.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit

final class AppCoordinator {
    enum Route {
        case equalizer
    }

    private var navigationController: UINavigationController?

    private let playerService: AudioPlayerService
    private let equaliserService: EqualizerService

    init() {
        playerService = AudioPlayerService()
        equaliserService = EqualizerService(playerService: playerService)
    }

    func start(window: UIWindow) {
        window.rootViewController = buildMain()
        window.makeKeyAndVisible()
    }

    private func buildMain() -> UINavigationController {
        let playlistItemsService = PlaylistItemsService(initialItemsProvider: provideInitialPlaylistItems)
        let viewModel = PlayerViewModel(playlistItemsService: playlistItemsService,
                                        playerService: playerService,
                                        routeTo: { [weak self] in self?.routeTo($0) })
        let viewController = PlayerViewController(viewModel: viewModel,
                                                  controlsProvider: providePlayerControls)

        let navigationController = UINavigationController(rootViewController: viewController)
        self.navigationController = navigationController
        return navigationController
    }

    private func routeTo(_ route: AppCoordinator.Route) {
        switch route {
        case .equalizer:
            showEqualizerControls()
        }
    }

    private func providePlayerControls() -> UIViewController {
        let viewModel = PlayerControlsViewModel(playerService: playerService)
        return PlayerControlsViewController(viewModel: viewModel)
    }

    private func showEqualizerControls() {
        let viewModel = EqualzerViewModel(equalizerService: equaliserService)
        let viewController = EqualizerViewController(viewModel: viewModel)
        let navigationController = UINavigationController(rootViewController: viewController)
        self.navigationController?.present(navigationController, animated: true, completion: nil)
    }
}
