//
//  ViewController.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 20/05/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import AudioStreaming
import AVFoundation
import UIKit

enum AudioContent: Int, CaseIterable {
    case offradio
    case enlefko
    case pepper966
    case radiox
    case khruangbin
    case piano
    case local

    var title: String {
        switch self {
        case .offradio:
            return "Offradio (stream)"
        case .enlefko:
            return "Enlefko (stream)"
        case .pepper966:
            return "Pepper 96.6 (stream)"
        case .radiox:
            return "Radio X (stream)"
        case .khruangbin:
            return "Khruangbin (mp3 preview)"
        case .piano:
            return "Piano (mp3)"
        case .local:
            return "Local file (mp3)"
        }
    }

    var streamUrl: URL {
        switch self {
        case .enlefko:
            return URL(string: "https://stream.radiojar.com/srzwv225e3quv")!
        case .offradio:
            return URL(string: "http://s3.yesstreaming.net:7033/stream")!
        case .pepper966:
            return URL(string: "https://ample-09.radiojar.com/pepper.m4a?1593699983=&rj-tok=AAABcw_1KyMAIViq2XpI098ZSQ&rj-ttl=5")!
        case .radiox:
            return URL(string: "https://media-ssl.musicradio.com/RadioXLondon")!
        case .khruangbin:
            return URL(string: "https://p.scdn.co/mp3-preview/cab4b09c23ffc11774d879977131df9d150fcef4?cid=d8a5ed958d274c2e8ee717e6a4b0971d")!
        case .piano:
            return URL(string: "https://www.kozco.com/tech/piano2-CoolEdit.mp3")!
        case .local:
            let path = Bundle.main.path(forResource: "bensound-jazzyfrenchy", ofType: "mp3")!
            return URL(fileURLWithPath: path)
        }
    }
}

class ViewController: UIViewController {
    let player: AudioPlayer = {
        let config = AudioPlayerConfiguration(enableLogs: true)
        return AudioPlayer(configuration: config)
    }()

    let resumeButton = UIButton()
    let muteButton = UIButton()

    let slider = UISlider()
    let elapsedPlayTimeLabel = UILabel()
    let remainingPlayTimeLabel = UILabel()
    let metadataLabel = UILabel()

    private var displayLink: CADisplayLink?

    override func viewDidLoad() {
        super.viewDidLoad()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.1)
        try? AVAudioSession.sharedInstance().setActive(true)

        player.delegate = self

        let buttons = AudioContent.allCases.map(buildButton(for:))

        let stackView = UIStackView(arrangedSubviews: buttons)
        stackView.spacing = 5
        stackView.axis = .vertical
        stackView.distribution = .fill
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stackView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 20),
            stackView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -20),
        ])

        muteButton.setTitle("Mute", for: .normal)
        if #available(iOS 13.0, *) {
            muteButton.setTitleColor(.label, for: .normal)
            muteButton.setTitleColor(.secondaryLabel, for: .highlighted)
            muteButton.setTitleColor(.tertiaryLabel, for: .disabled)
        } else {
            muteButton.setTitleColor(.black, for: .normal)
            muteButton.setTitleColor(.gray, for: .highlighted)
            muteButton.setTitleColor(.lightGray, for: .disabled)
        }
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        resumeButton.setTitle("Pause", for: .normal)
        if #available(iOS 13.0, *) {
            resumeButton.setTitleColor(.label, for: .normal)
            resumeButton.setTitleColor(.secondaryLabel, for: .highlighted)
            resumeButton.setTitleColor(.tertiaryLabel, for: .disabled)
        } else {
            resumeButton.setTitleColor(.black, for: .normal)
            resumeButton.setTitleColor(.gray, for: .highlighted)
            resumeButton.setTitleColor(.lightGray, for: .disabled)
        }
        resumeButton.addTarget(self, action: #selector(pauseResume), for: .touchUpInside)
        resumeButton.translatesAutoresizingMaskIntoConstraints = false

        let stopButton = UIButton(type: .custom)
        stopButton.setTitle("Stop", for: .normal)
        if #available(iOS 13.0, *) {
            stopButton.setTitleColor(.label, for: .normal)
            stopButton.setTitleColor(.secondaryLabel, for: .highlighted)
            stopButton.setTitleColor(.tertiaryLabel, for: .disabled)
        } else {
            stopButton.setTitleColor(.black, for: .normal)
            stopButton.setTitleColor(.darkGray, for: .highlighted)
        }
        stopButton.addTarget(self, action: #selector(stop), for: .touchUpInside)

        let controlsStackView = UIStackView(arrangedSubviews: [resumeButton, stopButton, muteButton])
        controlsStackView.translatesAutoresizingMaskIntoConstraints = false
        controlsStackView.spacing = 10
        controlsStackView.axis = .horizontal
        controlsStackView.distribution = .fillEqually
        controlsStackView.alignment = .center

        if #available(iOS 13.0, *) {
            slider.tintColor = .systemGray2
            slider.thumbTintColor = .systemGray
        } else {
            slider.tintColor = .darkGray
            slider.thumbTintColor = .black
        }
        slider.isContinuous = true
        slider.semanticContentAttribute = .playback
        slider.addTarget(self, action: #selector(sliderTouchedDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchedUp), for: [.touchUpInside, .touchUpOutside])
        slider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)

        elapsedPlayTimeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        elapsedPlayTimeLabel.textAlignment = .left
        remainingPlayTimeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        remainingPlayTimeLabel.textAlignment = .right

        let playbackTimeLabelsStack = UIStackView(arrangedSubviews: [elapsedPlayTimeLabel, remainingPlayTimeLabel])
        playbackTimeLabelsStack.translatesAutoresizingMaskIntoConstraints = false
        playbackTimeLabelsStack.axis = .horizontal
        playbackTimeLabelsStack.distribution = .fillEqually

        let controlsAndSliderStack = UIStackView(arrangedSubviews: [controlsStackView, slider, playbackTimeLabelsStack, metadataLabel])
        controlsAndSliderStack.translatesAutoresizingMaskIntoConstraints = false
        controlsAndSliderStack.spacing = 10
        controlsAndSliderStack.setCustomSpacing(5, after: slider)
        controlsAndSliderStack.axis = .vertical
        controlsAndSliderStack.distribution = .fillEqually

        view.addSubview(controlsAndSliderStack)
        NSLayoutConstraint.activate([
            controlsAndSliderStack.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 40),
            controlsAndSliderStack.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 20),
            controlsAndSliderStack.rightAnchor.constraint(equalTo: view.rightAnchor, constant: -20),
        ])
    }

    func buildButton(for content: AudioContent) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        if #available(iOS 13.0, *) {
            button.setTitleColor(.label, for: .normal)
        } else {
            button.setTitleColor(.black, for: .normal)
        }
        button.setTitle(content.title, for: .normal)
        button.tag = content.rawValue // being naive
        button.addTarget(self, action: #selector(play), for: .touchUpInside)
        return button
    }

    var seekValue: Float = 0
    var isScrubbing: Bool = false
    @objc
    func sliderTouchedDown() {
        isScrubbing = true
    }

    @objc
    func sliderTouchedUp() {
        isScrubbing = false
        if player.duration > 0 {
            player.seek(to: Double(slider.value))
        }
    }

    @objc
    func sliderValueChanged() {
        seekValue = slider.value
    }

    @objc
    func play(button: UIButton) {
        if let content = AudioContent(rawValue: button.tag) {
            player.play(url: content.streamUrl)
            resumeButton.setTitle("Pause", for: .normal)
            startDisplayLink()
            resetLabelsAndSlider()
        }
    }

    @objc
    func stop() {
        player.stop()
        resumeButton.setTitle("Pause", for: .normal)
        stopDisplayLink(resetLabels: true)
    }

    @objc
    func pauseResume() {
        if player.state == .playing {
            player.pause()
            resumeButton.setTitle("Resume", for: .normal)
            stopDisplayLink(resetLabels: false)
        } else if player.state == .paused {
            player.resume()
            resumeButton.setTitle("Pause", for: .normal)
            startDisplayLink()
        }
    }

    @objc
    func toggleMute() {
        player.muted = !player.muted
        muteButton.setTitle(player.muted ? "Unmute" : "Mute", for: .normal)
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = UIScreen.main.displayLink(withTarget: self, selector: #selector(tick))
        displayLink?.preferredFramesPerSecond = 6
        displayLink?.add(to: .current, forMode: .common)
    }

    private func stopDisplayLink(resetLabels: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        if resetLabels {
            resetLabelsAndSlider()
        }
    }

    private func resetLabelsAndSlider() {
        elapsedPlayTimeLabel.text = nil
        remainingPlayTimeLabel.text = nil
        slider.value = 0
        slider.maximumValue = 0
    }

    @objc
    private func tick() {
        let duration = player.duration
        let progress = player.progress
        if duration > 0 {
            let elapsed = Int(progress)
            let remaining = Int(duration - progress)

            slider.minimumValue = 0
            slider.maximumValue = Float(duration)
            if !isScrubbing {
                slider.value = Float(progress)
            }

            elapsedPlayTimeLabel.text = timeFrom(seconds: elapsed)
            remainingPlayTimeLabel.text = timeFrom(seconds: remaining)
        } else {
            let elapsed = Int(progress)
            elapsedPlayTimeLabel.text = "Live broadcast"
            remainingPlayTimeLabel.text = timeFrom(seconds: elapsed)
        }
    }

    private func timeFrom(seconds: Int) -> String {
        let correctSeconds = seconds % 60
        let minutes = (seconds / 60) % 60
        let hours = seconds / 3600

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, correctSeconds)
        }
        return String(format: "%02d:%02d", minutes, correctSeconds)
    }
}

extension ViewController: AudioPlayerDelegate {
    func audioPlayerDidCancel(player _: AudioPlayer, queuedItems _: [AudioEntryId]) {
        print("did cancel items")
    }

    func audioPlayerDidStartPlaying(player _: AudioPlayer, with _: AudioEntryId) {
//        print("did start playing: \(entryId)")
        metadataLabel.text = ""
    }

    func audioPlayerDidFinishBuffering(player _: AudioPlayer, with _: AudioEntryId) {
//        print("did finish buffering: \(entryId)")
    }

    func audioPlayerStateChanged(player _: AudioPlayer, with _: AudioPlayerState, previous _: AudioPlayerState) {
//        print("player state changed from: \(previous) to: \(newState)")
    }

    func audioPlayerDidFinishPlaying(player _: AudioPlayer, entryId _: AudioEntryId, stopReason _: AudioPlayerStopReason, progress _: Double, duration _: Double) {
//        print("player finished playing for: \(entryId)")
//        print("===> stop reason: \(stopReason)")
//        print("===> progress: \(progress)")
//        print("===> duration: \(duration)")
    }

    func audioPlayerUnexpectedError(player _: AudioPlayer, error _: AudioPlayerError) {
//        print("player error'd unexpectedly: \(error)")
    }

    func audioPlayerDidReadMetadata(player _: AudioPlayer, metadata: [String: String]) {
        print("player did read metadata")
        print("metadata: \(metadata)")
        guard !metadata.isEmpty else { return }
        if let title = metadata["StreamTitle"] {
            metadataLabel.text = "Now Playing: \(title)"
        } else {
            metadataLabel.text = ""
        }
    }
}
