//
//  AudioSessionManager.swift
//  AudioStreaming
//
//  Created by Dionisis Karatzas.
//  Copyright © 2025 Dionisis Karatzas. All rights reserved.
//

#if !os(macOS)
    import Foundation
    import AVFoundation

    /// Protocol for handling audio session interruptions and route changes
    public protocol AudioSessionInterruptionDelegate: AnyObject {
        func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions)
        func handleRouteChange(reason: AVAudioSession.RouteChangeReason, previousRoute: AVAudioSessionRouteDescription)
    }

    /// A class to manage the audio session configuration, interruptions, and route changes
    public final class AudioSessionManager {
        /// The shared audio session manager instance
        public static let shared = AudioSessionManager()

        /// Delegate to handle audio session interruptions and route changes
        public weak var interruptionDelegate: AudioSessionInterruptionDelegate?

        /// A Boolean value indicating whether the audio session is active
        private(set) var isSessionActive = false

        /// Notification observers
        private var interruptionObserver: NSObjectProtocol?
        private var routeChangeObserver: NSObjectProtocol?

        private init() {
            setupNotifications()
        }

        deinit {
            removeNotifications()
        }

        /// Sets up the audio session for playing audio
        ///
        /// - Parameter active: A Boolean value indicating whether to activate the audio session
        /// - Throws: An error if the audio session could not be configured
        public func setupSession(active: Bool) {
            let session = AVAudioSession.sharedInstance()

            try? session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay, .mixWithOthers])
            try? session.setActive(active)

            isSessionActive = active
        }

        /// Activates the audio session
        ///
        /// - Throws: An error if the audio session could not be activated
        public func activateSession() {
            if !isSessionActive {
                setupSession(active: true)
            }
        }

        /// Deactivates the audio session
        ///
        /// - Throws: An error if the audio session could not be deactivated
        public func deactivateSession() {
            if isSessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                isSessionActive = false
            }
        }

        // MARK: - Private

        private func setupNotifications() {
            let notificationCenter = NotificationCenter.default

            interruptionObserver = notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruptionNotification(notification)
            }

            routeChangeObserver = notificationCenter.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChangeNotification(notification)
            }
        }

        private func removeNotifications() {
            let notificationCenter = NotificationCenter.default

            if let interruptionObserver {
                notificationCenter.removeObserver(interruptionObserver)
            }

            if let routeChangeObserver {
                notificationCenter.removeObserver(routeChangeObserver)
            }
        }

        private func handleInterruptionNotification(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            var options = AVAudioSession.InterruptionOptions()
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            }

            interruptionDelegate?.handleInterruption(type: type, options: options)
        }

        private func handleRouteChangeNotification(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                return
            }

            let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription ?? AVAudioSessionRouteDescription()

            interruptionDelegate?.handleRouteChange(reason: reason, previousRoute: previousRoute)
        }
    }
#endif
