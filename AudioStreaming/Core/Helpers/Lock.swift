//
//  Created by Dimitrios Chatzieleftheriou on 27/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

protocol Lock {
    func lock()
    func unlock()

    // Execute a closure while acquiring a lock and returns the closure value
    func withLock<Result>(body: () throws -> Result) rethrows -> Result

    // Execute a closure while acquiring a lock
    func withLock(body: () -> Void)
}

/// A wrapper for `os_unfair_lock`
/// - Tag: UnfairLock
final class UnfairLock: Lock {
    @usableFromInline let unfairLock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deallocate()
    }

    @inlinable
    @inline(__always)
    func withLock<Result>(body: () throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return try body()
    }

    @inlinable
    @inline(__always)
    func withLock(body: () -> Void) {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        body()
    }

    @inlinable
    @inline(__always)
    func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    @inlinable
    @inline(__always)
    func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}
