//
//  Created by Dimitrios Chatzieleftheriou on 27/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

protocol Lock {
    func lock()
    func unlock()
}

extension Lock {
    // Execute a closure while acquiring a lock and returns the closure value
    @inline(__always)
    func around<Value>(_ closure: () -> Value) -> Value {
        lock(); defer { unlock() }
        return closure()
    }

    // Execute a closure while acquiring a lock
    @inline(__always)
    func around(_ closure: () -> Void) {
        lock(); defer { unlock() }
        closure()
    }
}

/// A wrapper for `os_unfair_lock`
/// - Tag: UnfairLock
final class UnfairLock: Lock {
    private let unfairLock: os_unfair_lock_t

    internal init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inline(__always)
    internal func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    @inline(__always)
    internal func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}
