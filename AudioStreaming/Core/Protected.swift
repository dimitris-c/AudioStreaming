//
//  Created by Dimitrios Chatzieleftheriou on 21/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

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
internal final class UnfairLock: Lock {
    private let unfairLock: os_unfair_lock_t

    internal init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }

    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }

    internal func lock() {
        os_unfair_lock_lock(unfairLock)
    }

    internal func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}

@propertyWrapper
internal final class Atomic<Value> {
    var wrappedValue: Value { lock.around { value } }

    var projectedValue: Atomic<Value> { self }

    private let lock = UnfairLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    func read<Element>(_ closure: (Value) -> Element) -> Element {
        lock.around { closure(self.value) }
    }

    @discardableResult
    func write<Element>(_ closure: (inout Value) -> Element) -> Element {
        lock.around { closure(&self.value) }
    }
}
