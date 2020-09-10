//
//  ViewController.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 20/05/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import UIKit
import AudioStreaming
import AVFoundation

enum AudioContent: Int, CaseIterable {
    case offradio
    case enlefko
    case pepper966
    case radiox
    case khruangbin
    case flac
    case piano
    
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
            case .flac:
                return "Sample audio (flac)"
            case .piano:
                return "Piano (mp3)"
        }
    }
    
    var streamUrl: URL {
        switch self {
            case .enlefko:
                return URL(string: "https://ample-02.radiojar.com/srzwv225e3quv?rj-ttl=5&rj-tok=AAABcmnuHngA2PJ4KSBI9k5cCw")!
            case .offradio:
                return URL(string: "http://s3.yesstreaming.net:7033/stream")!
            case .pepper966:
                return URL(string: "https://ample-09.radiojar.com/pepper.m4a?1593699983=&rj-tok=AAABcw_1KyMAIViq2XpI098ZSQ&rj-ttl=5")!
            case .radiox:
                return URL(string: "https://media-ssl.musicradio.com/RadioXLondon")!
            case .khruangbin:
//                return URL(string: "https://p.scdn.co/mp3-preview/cab4b09c23ffc11774d879977131df9d150fcef4?cid=d8a5ed958d274c2e8ee717e6a4b0971d")!
                return URL(string: "https://t4.bcbits.com/stream/fdb938c3d5eb62c9ff8587af2725c9d3/mp3-128/2809605460?p=0&ts=1599833677&t=a009097dd0968ae23b619e639e28726772c3875b&token=1599833677_3bf55c415b5412c133c9da03648381e77329f1db")!
            case .flac:
                return URL(string: "http://www.lindberg.no/hires/test/2L-145_01_stereo_01.cd.flac")!
            case .piano:
                return URL(string: "https://www.kozco.com/tech/piano2-CoolEdit.mp3")!
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
        self.view.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stackView.leftAnchor.constraint(equalTo: self.view.leftAnchor, constant: 20),
            stackView.rightAnchor.constraint(equalTo: self.view.rightAnchor, constant: -20)
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
        
        self.view.addSubview(controlsAndSliderStack)
        NSLayoutConstraint.activate([
            controlsAndSliderStack.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 40),
            controlsAndSliderStack.leftAnchor.constraint(equalTo: self.view.leftAnchor, constant: 20),
            controlsAndSliderStack.rightAnchor.constraint(equalTo: self.view.rightAnchor, constant: -20)
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
        displayLink?.add(to: .current, forMode: .default)
    }
    
    private func stopDisplayLink(resetLabels: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        if resetLabels {
            self.resetLabelsAndSlider()
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
        if player.duration() > 0 {
            let elapsed = Int(player.progress())
            let remaining = Int(player.duration() - (player.progress()))
            
            slider.minimumValue = 0
            slider.maximumValue = Float(player.duration())
            slider.value = Float(player.progress())
            
            elapsedPlayTimeLabel.text = timeFrom(seconds: elapsed)
            remainingPlayTimeLabel.text = timeFrom(seconds: remaining)            
        } else {
            let elapsed = Int(player.progress())
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
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {
        print("did cancel items")
    }
    
    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {
        print("did start playing: \(entryId)")
        metadataLabel.text = ""
    }
    
    func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {
        print("did finish buffering: \(entryId)")
    }
    
    func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        print("player state changed from: \(previous) to: \(newState)")
    }
    
    func audioPlayerDidFinishPlaying(player: AudioPlayer, entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        print("player finished playing for: \(entryId)")
        print("===> stop reason: \(stopReason)")
        print("===> progress: \(progress)")
        print("===> duration: \(duration)")
    }
    
    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
        print("player error'd unexpectedly: \(error)")
    }
    
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String : String]) {
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
