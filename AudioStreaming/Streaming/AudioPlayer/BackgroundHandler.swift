//
//  BackgroundHandler.swift
//  AudioStreaming
//
//  Created by Dionisis Karatzas.
//  Copyright © 2025 Dionisis Karatzas. All rights reserved.
//

#if os(macOS)
    import Foundation // No background-task API on macOS
#else
    import UIKit
#endif

/// A tiny wrapper around `beginBackgroundTask` / `endBackgroundTask`.
/// Call it from **any** queue; it hops to the main queue when needed.
final class BackgroundHandler: @unchecked Sendable {
    // MARK: – RAII token
    final class Token {
        private weak var owner: BackgroundHandler?
        fileprivate init(_ owner: BackgroundHandler) { self.owner = owner }
        public func end() {
            #if !os(macOS)
                owner?.endBackgroundTask()
            #endif
        }

        deinit { end() }
    }

    #if !os(macOS)
        private let app: UIApplication = .shared
        private var taskID: UIBackgroundTaskIdentifier?
    #endif
    private var counter: UInt = 0

    // MARK: – Public API -------------------------------------------------------

    #if !os(macOS)

        /// Begin a task **only when the app is already in the background**.
        @discardableResult
        func beginIfBackgrounded(reason: String = "unspecified") -> Token? {
            if !Thread.isMainThread { // hop once if caller is off-main
                return DispatchQueue.main.sync { beginIfBackgrounded(reason: reason) }
            }

            guard app.applicationState != .active else {
                return nil
            }
            return beginBackgroundTask(reason: reason)
        }

        /// Begin a task unconditionally (foreground or background).
        @discardableResult
        func beginBackgroundTask(reason: String = "unspecified") -> Token? {
            counter += 1
            if taskID != nil {
                return Token(self)
            } // nested begin

            var createdID: UIBackgroundTaskIdentifier = .invalid
            let register: () -> Void = { [weak self] in
                guard let self else {
                    return
                }
                createdID = self.app.beginBackgroundTask(withName: reason) { [weak self] in
                    self?.endBackgroundTask(expired: true)
                }
                if createdID != .invalid {
                    self.taskID = createdID
                }
            }
            Thread.isMainThread ? register() : DispatchQueue.main.sync(execute: register)

            if createdID == .invalid { // system refused
                counter -= 1
                return nil
            }
            return Token(self)
        }

        /// Finish one reference; ends the system task when the ref-count hits 0.
        @discardableResult
        func endBackgroundTask(expired: Bool = false) -> Bool {
            guard let id = taskID else {
                return false
            }
            counter = counter > 0 ? counter - 1 : 0
            if counter > 0 {
                return false
            }

            let finish: () -> Void = { [weak self] in
                guard let self else {
                    return
                }
                self.app.endBackgroundTask(id)
            }
            Thread.isMainThread ? finish() : DispatchQueue.main.sync(execute: finish)

            taskID = nil
            return true
        }

    #endif

    deinit {
        #if !os(macOS)
            _ = endBackgroundTask()
        #endif
    }
}
