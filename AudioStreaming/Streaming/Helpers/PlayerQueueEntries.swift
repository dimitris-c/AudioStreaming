//
//  Created by Dimitrios Chatzieleftheriou on 04/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

enum PlayerQueueType {
    case upcoming
    case buffering
}

/// Handles the buffering and upcoming upcoming `AudioEntries`
/// The underlying objects are defined as `Queue<AudioEntry>`
final class PlayerQueueEntries {
    private let lock = UnfairLock()
    private var bufferring: Queue<AudioEntry>
    private var upcoming: Queue<AudioEntry>

    /// Returns `true` when both underlying entries are empty
    var isEmpty: Bool {
        lock.around {
            bufferring.isEmpty && upcoming.isEmpty
        }
    }

    /// Returns the count of both underlying entries
    var count: Int {
        lock.around {
            bufferring.count + upcoming.count
        }
    }

    init() {
        bufferring = Queue<AudioEntry>()
        upcoming = Queue<AudioEntry>()
    }

    /// Adds the `item` to the underlying queue for the specified `type`
    /// - parameter item: An `AudioEntry` object to be added
    /// - parameter type: The type fo the underlying queue as expressed by `PlayerQueueType`
    func enqueue(item: AudioEntry, type: PlayerQueueType) {
        lock.lock(); defer { lock.unlock() }
        queue(for: type).enqueue(item: item)
    }

    /// Returns and removes the `item` to the underlying queue for the specified `type`
    /// - parameter item: An `AudioEntry` object to be added
    /// - parameter type: The type fo the underlying queue as expressed by `PlayerQueueType`
    /// - returns: An `AudioEntry` if found
    func dequeue(type: PlayerQueueType) -> AudioEntry? {
        lock.lock(); defer { lock.unlock() }
        return queue(for: type).dequeue()
    }

    /// Appends (skips) the `items` to the underlying queue for the specified `type`
    /// - parameter item: An `AudioEntry` object to be added
    /// - parameter type: The type fo the underlying queue as expressed by `PlayerQueueType`
    func skip(items: [AudioEntry], type: PlayerQueueType) {
        lock.lock(); defer { lock.unlock() }
        queue(for: type).skip(items: items)
    }

    /// Append (skip) the `item` to the underlying queue for the specified `type`
    /// - parameter item: An `AudioEntry` object to be added
    /// - parameter type: The type fo the underlying queue as expressed by `PlayerQueueType`
    func skip(item: AudioEntry, type: PlayerQueueType) {
        lock.lock(); defer { lock.unlock() }
        queue(for: type).skip(item: item)
    }

    func count(for type: PlayerQueueType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return queue(for: type).count
    }

    /// Removes all elements from the specified queue type
    func removeAll(for type: PlayerQueueType) {
        lock.lock(); defer { lock.unlock() }
        queue(for: type).removeAll()
    }

    /// Removes all elements from all queue type
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        queue(for: .buffering).removeAll()
        queue(for: .upcoming).removeAll()
    }

    /// Returns an array of `AudioEntryId` of both underlying queues
    /// - returns: The newly constructed array of `AudioEntryId` objects
    func pendingEntriesId() -> [AudioEntryId] {
        lock.lock(); defer { lock.unlock() }
        let upcomingIds = upcoming.map { $0.id }
        let bufferingIds = bufferring.map { $0.id }
        return upcomingIds + bufferingIds
    }

    func requeueBufferingEntries(block: (AudioEntry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let bufferring = queue(for: .buffering)
        bufferring.forEach(block)
        let bufferringItems = bufferring.map { $0 }
        queue(for: .upcoming).skip(items: bufferringItems)
        queue(for: .buffering).removeAll()
    }

    /// - parameter type: A `PlayerQueueType`
    /// - returns: The appropriate queue for given type
    private func queue(for type: PlayerQueueType) -> Queue<AudioEntry> {
        switch type {
        case .buffering:
            return bufferring
        case .upcoming:
            return upcoming
        }
    }
}

extension PlayerQueueEntries: CustomDebugStringConvertible {
    var debugDescription: String {
        "PlayerQueue upcoming: \(upcoming.count), buffering: \(bufferring.count)"
    }
}
