//
//  Created by Dimitrios Chatzieleftheriou on 04/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

/**
 Operations visualised below
 ```
    enqueue(item: 1)
    +---+
    | 1 |
    +---+
    enqueue(item: 2)
    +---+ +---+
    | 2 | | 1 |
    +---+ +---+
    skip(item: 3), skip(items: [3, 4])
    +---+ +---+ +---+
    | 2 | | 1 | | 3 |
    +---+ +---+ +---+

    dequeue() -> 3
    +---+ +---+
    | 2 | | 1 |
    +---+ +---+
 ```
 */
final class Queue<Element>: Sequence, CustomDebugStringConvertible {
    private var _storage: [Element] = []

    var isEmpty: Bool { _storage.isEmpty }

    var count: Int { _storage.count }

    /// Inserts an item at the end of the queue
    func enqueue(item: Element) {
        _storage.insert(item, at: 0)
    }

    /// Removes and returns the last item
    func dequeue() -> Element? {
        guard !isEmpty else { return nil }
        return _storage.removeLast()
    }

    /// Adds element at the front of the queue
    func skip(item: Element) {
        _storage.append(item)
    }

    /// Adds elements at the front of the queue
    func skip(items: [Element]) {
        for item in items {
            _storage.append(item)
        }
    }

    /// Retrieves the last item
    func peek() -> Element? {
        _storage.last
    }

    /// Revoves all elements
    func removeAll() {
        _storage.removeAll()
    }

    func makeIterator() -> Array<Element>.Iterator {
        _storage.makeIterator()
    }

    var debugDescription: String {
        return "Queue with elements: \(_storage)"
    }
}
