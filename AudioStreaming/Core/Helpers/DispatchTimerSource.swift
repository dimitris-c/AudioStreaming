//
//  Created by Dimitrios Chatzieleftheriou on 08/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

/**
 A Timer implementation using `DispatchSource.makeTimerSource`.
 */
final class DispatchTimerSource {
    private var handler: (() -> Void)?
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var _state: SourceState = .suspended

    /// The state of the timer
    enum SourceState {
        case activated
        case suspended
    }

    /// Read-only: the suspend/resume balance is only correct when the state check and the state
    /// change happen together under the lock, which is what `activate()`/`suspend()` do.
    var state: SourceState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    var isRunning: Bool {
        state == .activated
    }

    /// Initializes an new `DispatchTimerSource`
    ///
    /// - parameter interval: A `DispatchTimeInterval` value indicating the interval of te timer.
    /// - parameter queue: An optional `DispatchQueue` in which to execute the installed handlers.
    required init(queue: DispatchQueue?) {
        timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
    }

    convenience init(interval: DispatchTimeInterval, queue: DispatchQueue?, repeats: Bool = true) {
        self.init(queue: queue)
        schedule(interval: interval, repeats: repeats)
    }

    deinit {
        timer.setEventHandler(handler: nil)
        timer.cancel()
        // A suspended dispatch source traps if it is released without being resumed first — but
        // resuming one that is already running is an over-resume, which traps just the same. The
        // balancing resume therefore has to be conditional: this object is routinely deallocated
        // while its timer is still activated, e.g. a pending retry whose owner goes away.
        lock.lock()
        let needsResume = _state == .suspended
        _state = .activated
        lock.unlock()

        if needsResume {
            timer.resume()
        }
    }

    /// Adds an event handler to the timer.
    ///
    /// - parameter handler: A closure for the event handler
    func add(handler: @escaping () -> Void) {
        let handler = handler
        timer.setEventHandler(handler: handler)
    }

    /// Removes the added event handler from the timer.
    func removeHandler() {
        timer.setEventHandler(handler: nil)
    }

    /// Activates the timer, if needed
    func activate() {
        lock.lock()
        defer { lock.unlock() }

        guard _state == .suspended else { return }
        _state = .activated
        timer.resume()
    }

    /// Suspends the timer, if needed.
    func suspend() {
        lock.lock()
        defer { lock.unlock() }

        guard _state == .activated else { return }
        _state = .suspended
        timer.suspend()
    }

    func schedule(interval: DispatchTimeInterval, repeats: Bool) {
        timer.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
    }
}
