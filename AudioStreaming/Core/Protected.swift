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
    func around<T>(_ closure: () -> T) -> T {
        lock(); defer { unlock() }
        return closure()
    }
    
    // Execute a closure while acquiring a lock
    func around(_ closure: () -> Void) {
        lock(); defer { unlock() }
        closure()
    }
}

/// A wrapper for `os_unfair_lock`
final public class UnfairLock {
    private let unfairLock: os_unfair_lock_t
    
    public init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        unfairLock.deinitialize(count: 1)
        unfairLock.deallocate()
    }
    
    public func lock() {
        os_unfair_lock_lock(unfairLock)
    }
    
    public func unlock() {
        os_unfair_lock_unlock(unfairLock)
    }
}

extension UnfairLock: Lock { }

func setLock(_ lock: os_unfair_lock_t) {
    os_unfair_lock_lock(lock)
}

func setUnlock(_ lock: os_unfair_lock_t) {
    os_unfair_lock_unlock(lock)
}

@propertyWrapper
final class Protected<Value> {
    private let lock = UnfairLock()
    private var value: Value
    
    init(wrappedValue: Value) {
        self.value = wrappedValue
    }
    
    var wrappedValue: Value {
        get { lock.around { value } }
    }

    var projectedValue: Protected<Value> { self }
    
    func read<Element>(_ closure: (Value) -> Element) -> Element {
        lock.around { closure(self.value) }
    }
    
    @discardableResult
    func write<Element>(_ closure: (inout Value) -> Element) -> Element {
        lock.around { closure(&self.value)  }
    }

}
