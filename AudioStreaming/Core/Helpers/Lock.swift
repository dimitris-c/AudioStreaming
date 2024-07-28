//
//  Created by Dimitrios Chatzieleftheriou on 27/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import os

protocol Lock {
    func lock()
    func unlock()

    // Execute a closure while acquiring a lock and returns the closure value
    func withLock<Result>(body: () throws -> Result) rethrows -> Result

    // Execute a closure while acquiring a lock
    func withLock(body: () -> Void)

    func deallocate()
}

/// A wrapper for `os_unfair_lock`
/// - Tag: UnfairLock
final class UnfairLock: Lock {

    var unfairLock: Lock

    init() {
        if #available(iOS 16.0, *), #available(macOS 13.0, *) {
            unfairLock = OSStorageLock()
        } else {
            unfairLock = UnfairStorageLock()
        }
    }

    deinit {
        deallocate()
    }

    func deallocate() {
        unfairLock.deallocate()
    }

    @inlinable
    func withLock<Result>(body: () throws -> Result) rethrows -> Result {
        try unfairLock.withLock(body: body)
    }

    @inlinable
    func withLock(body: () -> Void) {
        unfairLock.withLock(body: body)
    }

    @inlinable
    func lock() {
        unfairLock.lock()
    }

    @inlinable
    func unlock() {
        unfairLock.unlock()
    }
}

@available(iOS 16.0, *)
@available(macOS 13, *)
private class OSStorageLock: Lock {
    @usableFromInline
    let osLock = OSAllocatedUnfairLock()

    @inlinable
    func lock() {
        osLock.lock()
    }

    @inlinable
    func unlock() {
        osLock.unlock()
    }

    func withLock<Result>(body: () throws -> Result) rethrows -> Result {
        try osLock.withLockUnchecked(body)
    }

    func withLock(body: () -> Void) {
        osLock.withLockUnchecked(body)
    }

    func deallocate() {} // no-op
}

private class UnfairStorageLock: Lock {

    @usableFromInline
    let unfairLock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    func deallocate() {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    @inlinable
    func withLock<Result>(body: () throws -> Result) rethrows -> Result {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        return try body()
    }

    @inlinable
    func withLock(body: () -> Void) {
        os_unfair_lock_lock(unfairLock)
        defer { os_unfair_lock_unlock(unfairLock) }
        body()
    }

    @inlinable
    func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    @inlinable
    func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}
