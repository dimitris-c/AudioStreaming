//
//  PlayerControlsViewController.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit

class PlayerControlsViewController: UIViewController {
    private lazy var resumeButton = UIButton()
    private lazy var stopButton = UIButton(type: .custom)
    private lazy var muteButton = UIButton()

    private lazy var slider = UISlider()
    private lazy var elapsedPlayTimeLabel = UILabel()
    private lazy var remainingPlayTimeLabel = UILabel()

    private lazy var rateSlider = UISlider()
    private lazy var rateSliderValueLabel = UILabel()

    private lazy var playerStatus = UILabel()

    private let viewModel: PlayerControlsViewModel

    init(viewModel: PlayerControlsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        setupBinding()
    }

    private func setupUI() {
        muteButton.translatesAutoresizingMaskIntoConstraints = false
        muteButton.setTitle("Mute", for: .normal)
        muteButton.setTitleColor(.label, for: .normal)
        muteButton.setTitleColor(.secondaryLabel, for: .highlighted)
        muteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        muteButton.accessibilityIdentifier = "muteButton"
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        resumeButton.translatesAutoresizingMaskIntoConstraints = false
        resumeButton.setTitle("Pause", for: .normal)
        resumeButton.accessibilityIdentifier = "resumeButton"
        resumeButton.setTitleColor(.label, for: .normal)
        resumeButton.setTitleColor(.secondaryLabel, for: .highlighted)
        resumeButton.setTitleColor(.tertiaryLabel, for: .disabled)
        resumeButton.addTarget(self, action: #selector(pauseResume), for: .touchUpInside)

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setTitle("Stop", for: .normal)
        stopButton.setTitleColor(.label, for: .normal)
        stopButton.setTitleColor(.secondaryLabel, for: .highlighted)
        stopButton.setTitleColor(.tertiaryLabel, for: .disabled)
        stopButton.accessibilityIdentifier = "stopButton"
        stopButton.addTarget(self, action: #selector(stop), for: .touchUpInside)

        let controlsStackView = UIStackView(arrangedSubviews: [resumeButton, stopButton, muteButton])
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        controlsStackView.axis = .horizontal
        controlsStackView.distribution = .fillEqually
        controlsStackView.alignment = .center
        controlsStackView.accessibilityIdentifier = "controlsStackView"

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.accessibilityIdentifier = "slider"
        slider.tintColor = .systemGray2
        slider.thumbTintColor = .systemGray
        slider.isContinuous = true
        slider.semanticContentAttribute = .playback
        slider.addTarget(self, action: #selector(sliderTouchedDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchedUp), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)

        elapsedPlayTimeLabel.text = "--:--"
        elapsedPlayTimeLabel.accessibilityIdentifier = "elapsedPlayTimeLabel"
        elapsedPlayTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedPlayTimeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        elapsedPlayTimeLabel.textAlignment = .left
        remainingPlayTimeLabel.text = "--:--"
        remainingPlayTimeLabel.accessibilityIdentifier = "remainingPlayTimeLabel"
        remainingPlayTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        remainingPlayTimeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        remainingPlayTimeLabel.textAlignment = .right

        let playbackTimeLabelsStack = UIStackView(arrangedSubviews: [elapsedPlayTimeLabel, remainingPlayTimeLabel])
        playbackTimeLabelsStack.translatesAutoresizingMaskIntoConstraints = false
        playbackTimeLabelsStack.axis = .horizontal
        playbackTimeLabelsStack.distribution = .fillEqually
        playbackTimeLabelsStack.accessibilityIdentifier = "playbackTimeLabelsStack"

        playerStatus.text = ""
        playerStatus.translatesAutoresizingMaskIntoConstraints = false
        playerStatus.numberOfLines = 0
        playerStatus.accessibilityIdentifier = "playerStatus-label"

        let sliderLabel = UILabel()
        sliderLabel.translatesAutoresizingMaskIntoConstraints = false
        sliderLabel.text = "Rate: "

        rateSliderValueLabel.translatesAutoresizingMaskIntoConstraints = false
        rateSliderValueLabel.text = viewModel.currentRateTitle

        rateSlider.translatesAutoresizingMaskIntoConstraints = false
        rateSlider.minimumValue = viewModel.rateMinValue
        rateSlider.maximumValue = viewModel.rateMaxValue
        rateSlider.value = viewModel.rateMinValue
        rateSlider.addTarget(self, action: #selector(rateValueChanged), for: .valueChanged)

        let sliderWarningLabel = UILabel()
        sliderWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        sliderWarningLabel.text = "Adjusting rate in live broadcast is not recommended"
        sliderWarningLabel.numberOfLines = 2
        sliderWarningLabel.textColor = .systemRed

        let rateSliderStackView = UIStackView(arrangedSubviews: [sliderLabel, rateSlider, rateSliderValueLabel])
        rateSliderStackView.spacing = 10
        rateSliderStackView.axis = .horizontal

        let controlsAndSliderStack = UIStackView(arrangedSubviews: [controlsStackView,
                                                                    slider,
                                                                    playbackTimeLabelsStack,
                                                                    playerStatus,
                                                                    rateSliderStackView,
                                                                    sliderWarningLabel])
        controlsAndSliderStack.translatesAutoresizingMaskIntoConstraints = false
        controlsAndSliderStack.spacing = 10
        controlsAndSliderStack.setCustomSpacing(15, after: playbackTimeLabelsStack)
        controlsAndSliderStack.axis = .vertical
        controlsAndSliderStack.distribution = .fill
        controlsAndSliderStack.alignment = .fill
        controlsAndSliderStack.isLayoutMarginsRelativeArrangement = true
        controlsAndSliderStack.layoutMargins = .init(top: 15, left: 10, bottom: 0, right: 10)
        controlsAndSliderStack.accessibilityIdentifier = "controlsAndSliderStack"

        view.addSubview(controlsAndSliderStack)
        view.accessibilityIdentifier = "controller-view"

        NSLayoutConstraint.activate([
            controlsAndSliderStack.topAnchor.constraint(equalTo: view.topAnchor),
            controlsAndSliderStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsAndSliderStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupBinding() {
        viewModel.updateContent = { [unowned self] effect in
            switch effect {
            case let .updateMuteButton(title):
                self.muteButton.setTitle(title, for: .normal)
            case let .updatePauseResumeButton(title):
                self.resumeButton.setTitle(title, for: .normal)
            case let .updateSliderMinMaxValue(min, max):
                self.slider.minimumValue = min
                self.slider.maximumValue = max
            case let .updateSliderValue(value):
                self.slider.value = value
            case let .updateMetadata(title):
                self.playerStatus.text = title
            }
        }

        viewModel.updateProgressAndDurationTitles = { [elapsedPlayTimeLabel, remainingPlayTimeLabel] progress, duration in
            elapsedPlayTimeLabel.text = progress
            remainingPlayTimeLabel.text = duration
        }
    }

    @objc private func rateValueChanged() {
        viewModel.update(rate: rateSlider.value) { [rateSlider] value in
            rateSlider.value = value
        }
        rateSliderValueLabel.text = viewModel.currentRateTitle
    }

    @objc private func toggleMute() {
        viewModel.toggleMute()
    }

    @objc private func pauseResume() {
        viewModel.togglePauseResume()
    }

    @objc private func stop() {
        viewModel.stop()
    }

    @objc
    func sliderTouchedDown() {
        viewModel.seek(action: .started)
    }

    @objc
    func sliderTouchedUp() {
        viewModel.seek(action: .ended)
    }

    @objc
    func sliderValueChanged() {
        viewModel.seek(action: .updateSeek(time: slider.value))
    }
}
