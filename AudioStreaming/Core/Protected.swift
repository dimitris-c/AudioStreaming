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

/// A `pthread_mutex_t` wrapper.
final class Mutex: Lock {
    private var mutex: UnsafeMutablePointer<pthread_mutex_t>
    
    init() {
        mutex = .allocate(capacity: 1)
        
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutexattr_settype(&attr, .init(PTHREAD_MUTEX_RECURSIVE))
        
        let error = pthread_mutex_init(mutex, &attr)
        precondition(error == 0, "failure creating pthread_mutext")
    }
    
    deinit {
        let error = pthread_mutex_destroy(mutex)
        precondition(error == 0, "fulire destroying pthread_mutex")
    }
    
    func lock() {
        pthread_mutex_lock(mutex)
    }
    
    func unlock() {
        pthread_mutex_unlock(mutex)
    }
}

/// A wrapper for `os_unfair_lock`
@objcMembers
final public class UnfairLock: NSObject {
    let unfairLock: os_unfair_lock_t
    
    public override init() {
        unfairLock = .allocate(capacity: 1)
        unfairLock.initialize(to: os_unfair_lock())
        super.init()
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
