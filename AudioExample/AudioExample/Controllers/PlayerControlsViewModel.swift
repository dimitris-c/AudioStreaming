//
//  PlayerControlsViewModel.swift
//  AudioExample
//
//  Created by Dimitrios Chatzieleftheriou on 14/11/2020.
//  Copyright © 2020 Dimitrios Chatzieleftheriou. All rights reserved.
//

import AudioStreaming
import Foundation
import UIKit

enum SeekAction: Equatable {
    case started
    case updateSeek(time: Float)
    case ended
}

enum ControlsEffects {
    case updateMuteButton(String)
    case updatePauseResumeButton(String)
    case updateSliderMinMaxValue(min: Float, max: Float)
    case updateSliderValue(value: Float)
    case updateMetadata(String)
}

final class PlayerControlsViewModel {
    var updateContent: ((ControlsEffects) -> Void)?
    var updateProgressAndDurationTitles: ((String, String) -> Void)?

    private let playerService: AudioPlayerService

    private var displayLink: CADisplayLink?

    private var seekTime: Float = 0
    private var isScrubbing: Bool = false

    let rateMinValue: Float = 1.0
    let rateMaxValue: Float = 3.0

    var currentRateTitle: String {
        String(format: "%.1fx", playerService.rate)
    }

    init(playerService: AudioPlayerService) {
        self.playerService = playerService
        self.playerService.delegate.add(delegate: self)
    }

    func stop() {
        playerService.stop()
        stopDisplayLink(resetLabels: true)
        updateContent?(.updatePauseResumeButton("Pause"))
    }

    func togglePauseResume() {
        playerService.toggle()
        let isPaused = playerService.state == .paused
        updateContent?(.updatePauseResumeButton(isPaused ? "Resume" : "Pause"))
    }

    func toggleMute() {
        playerService.toggleMute()
        let isMuted = playerService.isMuted
        updateContent?(.updateMuteButton(isMuted ? "Unmute" : "Mute"))
    }

    func seek(action: SeekAction) {
        switch action {
        case .started:
            isScrubbing = true
            seekTime = 0
        case let .updateSeek(time):
            seekTime = time
        case .ended:
            isScrubbing = false
            if playerService.duration > 0 {
                playerService.seek(at: seekTime)
            }
        }
    }

    func update(rate: Float, updater: (Float) -> Void) {
        let rate = round(rate / 0.5) * 0.5
        playerService.update(rate: rate)
        updater(rate)
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
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

    @objc private func tick() {
        let duration = playerService.duration
        let progress = playerService.progress
        if duration > 0 {
            let elapsed = Int(progress)
            let remaining = Int(duration - progress)

            updateContent?(.updateSliderMinMaxValue(min: 0.0, max: Float(duration)))
            if !isScrubbing {
                updateContent?(.updateSliderValue(value: Float(progress)))
            }

            updateProgressAndDurationTitles?(timeFrom(seconds: elapsed), timeFrom(seconds: remaining))
        } else {
            let elapsed = Int(progress)
            updateProgressAndDurationTitles?("Live broadcast", timeFrom(seconds: elapsed))
        }
    }

    private func resetLabelsAndSlider() {
        updateProgressAndDurationTitles?("--:--", "--:--")
        updateContent?(.updateSliderMinMaxValue(min: 0, max: 0))
        updateContent?(.updateSliderValue(value: 0))
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

extension PlayerControlsViewModel: AudioPlayerServiceDelegate {
    func didStopPlaying() {
        stopDisplayLink(resetLabels: true)
        updateContent?(.updateMetadata(""))
    }

    func statusChanged(status _: AudioPlayerState) {}

    func didStartPlaying() {
        startDisplayLink()
        resetLabelsAndSlider()
        updateContent?(.updateMetadata(""))
    }

    func errorOccurred(error _: AudioPlayerError) {}

    func metadataReceived(metadata: [String: String]) {
        guard !metadata.isEmpty else { return }
        if let title = metadata["StreamTitle"] {
            updateContent?(.updateMetadata("Now Playing: \(title)"))
        } else {
            updateContent?(.updateMetadata(""))
        }
    }
}
