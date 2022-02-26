//
//  PlayerViewController.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit

class PlayerViewController: UIViewController {
    private lazy var tableView = UITableView()

    private let viewModel: PlayerViewModel
    private var controlsProvider: () -> UIViewController
    private var playerControlsController: UIViewController?

    init(viewModel: PlayerViewModel, controlsProvider: @escaping () -> UIViewController) {
        self.viewModel = viewModel
        self.controlsProvider = controlsProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()

        viewModel.reloadContent = { [weak self] action in
            switch action {
            case .all:
                self?.tableView.reloadData()
            case let .item(indexPath):
                self?.tableView.reloadRows(at: [indexPath], with: .automatic)
            }
        }
    }

    private func setupUI() {
        title = "Player"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                            target: self,
                                                            action: #selector(addNowPlaylistItem))

        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"),
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(showEqualizer))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(PlaylistTableViewCell.self, forCellReuseIdentifier: "PlaylistCell")

        let controlsController = controlsProvider()
        playerControlsController = controlsController

        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(tableView)

        addChild(controlsController)
        controlsController.view.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(controlsController.view)
        controlsController.didMove(toParent: self)

        view.addSubview(stackView)

        NSLayoutConstraint.activate(
            [
                controlsController.view.widthAnchor.constraint(equalTo: view.widthAnchor),
                stackView.topAnchor.constraint(equalTo: view.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ]
        )
    }

    @objc private func showEqualizer() {
        viewModel.showEqualizer()
    }

    @objc private func addNowPlaylistItem() {
        let controller = UIAlertController(title: "Add new item", message: "", preferredStyle: .alert)
        controller.addTextField { textField in
            textField.placeholder = "Insert url here"
        }
        let saveAction = UIAlertAction(title: "Save", style: .default) { [viewModel] _ in
            if let textfield = controller.textFields?.first,
               let text = textfield.text
            {
                viewModel.add(urlString: text)
            }
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)

        controller.addAction(saveAction)
        controller.addAction(cancelAction)
        present(controller, animated: true, completion: nil)
    }
}

extension PlayerViewController: UITableViewDataSource {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        viewModel.itemsCount
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PlaylistCell", for: indexPath)
        guard let item = viewModel.item(at: indexPath) else {
            return cell
        }
        cell.textLabel?.text = item.name
        cell.detailTextLabel?.text = item.queues ? "Queue item" : nil
        update(status: item.status, of: cell)
        return cell
    }

    private func update(status: PlaylistItem.Status, of cell: UITableViewCell) {
        switch status {
        case .buffering:
            let activity = UIActivityIndicatorView(style: .medium)
            activity.startAnimating()
            cell.accessoryView = activity
        case .playing:
            cell.accessoryView = UIImageView(image: UIImage(systemName: "play.fill"))
        case .paused:
            cell.accessoryView = UIImageView(image: UIImage(systemName: "pause.fill"))
        case .stopped:
            cell.accessoryView = nil
        }
        cell.accessoryView?.tintColor = .systemTeal
    }
}

extension PlayerViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        viewModel.playItem(at: indexPath)
    }
}

final class PlaylistTableViewCell: UITableViewCell {
    override init(style _: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
