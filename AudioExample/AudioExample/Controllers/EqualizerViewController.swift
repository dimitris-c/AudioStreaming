//
//  EqualizerViewController.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 15/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit

class EqualizerViewController: UIViewController {
    private lazy var enableTextLabel = UILabel()
    private lazy var enableButton = UISwitch()

    private var eqSlider = [UISlider]()

    private let viewModel: EqualzerViewModel

    init(viewModel: EqualzerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Equaliser"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetEq))

        enableTextLabel.translatesAutoresizingMaskIntoConstraints = false
        enableTextLabel.text = "Enable"

        enableButton.translatesAutoresizingMaskIntoConstraints = false
        enableButton.isOn = viewModel.equaliserIsOn
        enableButton.onTintColor = .systemTeal
        enableButton.addTarget(self, action: #selector(enableEq), for: .valueChanged)

        let enableStackView = UIStackView(arrangedSubviews: [enableTextLabel, enableButton])
        enableStackView.translatesAutoresizingMaskIntoConstraints = false
        enableStackView.axis = .horizontal
        enableStackView.alignment = .center
        enableStackView.spacing = 10
        enableStackView.isLayoutMarginsRelativeArrangement = true
        enableStackView.directionalLayoutMargins = .init(top: 10, leading: 10, bottom: 10, trailing: 10)

        let equaliserControls = UIStackView(arrangedSubviews: buildSliders())
        equaliserControls.translatesAutoresizingMaskIntoConstraints = false
        equaliserControls.axis = .vertical
        equaliserControls.alignment = .fill
        equaliserControls.distribution = .fillEqually

        let stackView = UIStackView(arrangedSubviews: [enableStackView, equaliserControls])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = .init(top: 10, leading: 10, bottom: 10, trailing: 10)

        view.addSubview(stackView)

        NSLayoutConstraint.activate(
            [
                enableStackView.heightAnchor.constraint(equalToConstant: 60),
                stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                stackView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.8),
            ]
        )
    }

    @objc func enableEq() {
        viewModel.enableEq(enableButton.isOn)
    }

    @objc func resetEq() {
        viewModel.resetEq { value in
            eqSlider.forEach { $0.setValue(value, animated: true) }
        }
    }

    private func buildSliders() -> [UIView] {
        var sliders = [UIView]()
        for index in 0 ..< viewModel.numberOfBands() {
            guard let item = viewModel.band(at: index) else { continue }
            let slider = buildSlider(item: item, index: index)
            sliders.append(slider)
        }
        return sliders
    }

    @objc private func valueChanged(_ slider: UISlider) {
        viewModel.update(gain: slider.value, for: slider.tag)
    }

    private func buildSlider(item: EQBand, index: Int) -> UIView {
        let freqLabel = UILabel()
        freqLabel.translatesAutoresizingMaskIntoConstraints = false
        freqLabel.text = item.frequency
        freqLabel.textAlignment = .right
        freqLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.tag = index // cheating here
        slider.minimumValue = item.min
        slider.maximumValue = item.max
        slider.value = item.value
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
        eqSlider.append(slider)

        let minLabel = UILabel()
        minLabel.translatesAutoresizingMaskIntoConstraints = false
        minLabel.text = "\(item.min)db"

        let centerLabel = UILabel()
        centerLabel.translatesAutoresizingMaskIntoConstraints = false
        centerLabel.text = "0db"
        centerLabel.textAlignment = .center

        let maxLabel = UILabel()
        maxLabel.translatesAutoresizingMaskIntoConstraints = false
        maxLabel.text = "\(item.max)db"
        maxLabel.textAlignment = .right

        let dbStackView = UIStackView(arrangedSubviews: [minLabel, centerLabel, maxLabel])
        dbStackView.translatesAutoresizingMaskIntoConstraints = false
        dbStackView.axis = .horizontal
        dbStackView.distribution = .fillEqually

        let stackViewSlider = UIStackView(arrangedSubviews: [slider, dbStackView])
        stackViewSlider.spacing = 5
        stackViewSlider.translatesAutoresizingMaskIntoConstraints = false
        stackViewSlider.axis = .vertical
        stackViewSlider.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        stackViewSlider.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)

        let stackView = UIStackView(arrangedSubviews: [freqLabel, stackViewSlider])
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.distribution = .fillProportionally
        stackView.alignment = .fill
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = .init(top: 0, leading: 10, bottom: 0, trailing: 10)

        return stackView
    }
}
