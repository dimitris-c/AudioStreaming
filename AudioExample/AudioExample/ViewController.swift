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
                return URL(string: "https://media-ssl.musicradio.com/RadioXUK?dax_version=release_1606&dax_player=GlobalPlayer&dax_platform=Web&dax_listenerid=1595318377694_0.6169900013451329&aisDelivery=streaming&listenerid=1595318377693_0.5828082361790362")!
            case .khruangbin:
                return URL(string: "https://p.scdn.co/mp3-preview/cab4b09c23ffc11774d879977131df9d150fcef4?cid=d8a5ed958d274c2e8ee717e6a4b0971d")!
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
        self.view.addSubview(controlsStackView)
        NSLayoutConstraint.activate([
            controlsStackView.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 40),
            controlsStackView.leftAnchor.constraint(equalTo: self.view.leftAnchor, constant: 20),
            controlsStackView.rightAnchor.constraint(equalTo: self.view.rightAnchor, constant: -20)
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
        }
    }
    
    @objc
    func stop() {
        player.stop()
        resumeButton.setTitle("Pause", for: .normal)
    }
    
    @objc
    func pauseResume() {
        if player.state == .playing {
            player.pause()
            resumeButton.setTitle("Resume", for: .normal)
        } else if player.state == .paused {
            player.resume()
            resumeButton.setTitle("Pause", for: .normal)
        }
    }
    
    @objc
    func toggleMute() {
        player.muted = !player.muted
        muteButton.setTitle(player.muted ? "Unmute" : "Mute", for: .normal)
    }
    
}

extension ViewController: AudioPlayerDelegate {
    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {
        print("did cancel items")
    }
    
    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {
        print("did start playing: \(entryId)")
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
    }
    
    
}
