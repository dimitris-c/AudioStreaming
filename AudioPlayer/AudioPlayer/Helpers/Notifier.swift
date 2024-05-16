//
//  Created by Dimitris Chatzieleftheriou on 25/04/2024.
//

import Foundation

actor Notifier<Output> {
    private var continuations: [UUID: AsyncStream<Output>.Continuation] = [:]

    func values(bufferingPolicy limit: AsyncStream<Output>.Continuation.BufferingPolicy = .bufferingNewest(1)) -> AsyncStream<Output> {
        AsyncStream<Output>(bufferingPolicy: limit) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.cancel(id) }
            }
        }
    }

    func send(_ value: Output) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }

    private func cancel(_ id: UUID) {
        continuations[id] = nil
    }
}
