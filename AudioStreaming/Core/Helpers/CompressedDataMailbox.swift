//
//  Created by Dimitrios Chatzieleftheriou on 22/08/2026.
//

import Foundation

/// Thread-safe state machine connecting network delivery to one serial consumer.
final class CompressedDataMailbox<Terminal> {
    struct EnqueueResult {
        let accepted: Bool
        let shouldScheduleDrain: Bool
        let shouldSuspendTransport: Bool
    }

    enum Next {
        case data(Data)
        case terminal(Terminal)
        case stop
    }

    private struct State {
        var buffer = CompressedDataBuffer()
        var inFlightByteCount = 0
        var terminal: Terminal?
        var drainScheduled = false
        var consumerSuspended = false
        var transportSuspended = false
        var generation: UInt64 = 0
    }

    private let highWatermark: Int
    private let lowWatermark: Int
    private let lock = UnfairLock()
    private var state = State()

    var generation: UInt64 {
        lock.withLock { state.generation }
    }

    var bufferedByteCount: Int {
        lock.withLock { state.buffer.byteCount }
    }

    var occupiedByteCount: Int {
        lock.withLock { occupiedByteCount(of: state) }
    }

    init(highWatermark: Int, lowWatermark: Int) {
        precondition(highWatermark > 0)
        precondition(lowWatermark >= 0 && lowWatermark < highWatermark)
        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
    }

    func enqueue(
        _ data: Data,
        generation: UInt64,
        canSuspendTransport: Bool = true
    ) -> EnqueueResult {
        lock.withLock {
            guard generation == state.generation, state.terminal == nil else {
                return rejectedEnqueueResult()
            }

            state.buffer.append(data)

            let shouldSuspendTransport = canSuspendTransport
                && occupiedByteCount(of: state) >= highWatermark
                && !state.transportSuspended
            if shouldSuspendTransport {
                state.transportSuspended = true
            }

            return EnqueueResult(
                accepted: true,
                shouldScheduleDrain: markDrainScheduledIfNeeded(state: &state),
                shouldSuspendTransport: shouldSuspendTransport
            )
        }
    }

    func finish(_ terminal: Terminal, generation: UInt64) -> EnqueueResult {
        lock.withLock {
            guard generation == state.generation, state.terminal == nil else {
                return rejectedEnqueueResult()
            }

            state.terminal = terminal
            state.transportSuspended = false
            return EnqueueResult(
                accepted: true,
                shouldScheduleDrain: markDrainScheduledIfNeeded(state: &state),
                shouldSuspendTransport: false
            )
        }
    }

    func suspendConsumer() {
        lock.withLock {
            state.consumerSuspended = true
        }
    }

    func resumeConsumer() -> Bool {
        lock.withLock {
            state.consumerSuspended = false
            return markDrainScheduledIfNeeded(state: &state)
        }
    }

    func next(generation: UInt64) -> Next {
        lock.withLock {
            guard generation == state.generation else { return .stop }
            guard !state.consumerSuspended else {
                state.drainScheduled = false
                return .stop
            }

            if let data = state.buffer.popFirst() {
                state.inFlightByteCount += data.count
                return .data(data)
            }

            if let terminal = state.terminal {
                state.terminal = nil
                state.drainScheduled = false
                return .terminal(terminal)
            }

            state.drainScheduled = false
            return .stop
        }
    }

    func completeData(byteCount: Int, generation: UInt64) -> Bool {
        lock.withLock {
            guard generation == state.generation else { return false }

            state.inFlightByteCount = max(0, state.inFlightByteCount - byteCount)
            let shouldResumeTransport = state.transportSuspended
                && occupiedByteCount(of: state) <= lowWatermark
            if shouldResumeTransport {
                state.transportSuspended = false
            }
            return shouldResumeTransport
        }
    }

    @discardableResult
    func reset() -> UInt64 {
        lock.withLock {
            state.generation &+= 1
            state.buffer = CompressedDataBuffer()
            state.inFlightByteCount = 0
            state.terminal = nil
            state.drainScheduled = false
            state.consumerSuspended = false
            state.transportSuspended = false
            return state.generation
        }
    }

    private func occupiedByteCount(of state: State) -> Int {
        state.buffer.byteCount + state.inFlightByteCount
    }

    private func markDrainScheduledIfNeeded(state: inout State) -> Bool {
        guard !state.consumerSuspended,
              !state.drainScheduled,
              !state.buffer.isEmpty || state.terminal != nil
        else {
            return false
        }

        state.drainScheduled = true
        return true
    }

    private func rejectedEnqueueResult() -> EnqueueResult {
        EnqueueResult(
            accepted: false,
            shouldScheduleDrain: false,
            shouldSuspendTransport: false
        )
    }
}

/// Lock-free FIFO used only while `CompressedDataMailbox.lock` is held.
private struct CompressedDataBuffer {
    private var storage: [Data] = []
    private var readIndex = 0

    private(set) var byteCount = 0

    var isEmpty: Bool {
        readIndex == storage.count
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.append(data)
        byteCount += data.count
    }

    mutating func popFirst() -> Data? {
        guard readIndex < storage.count else { return nil }

        let data = storage[readIndex]
        readIndex += 1
        byteCount -= data.count
        compactStorageIfNeeded()
        return data
    }

    private mutating func compactStorageIfNeeded() {
        guard readIndex >= 64, readIndex * 2 >= storage.count else { return }
        storage.removeFirst(readIndex)
        readIndex = 0
    }
}
