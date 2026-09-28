//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class NetworkDataStream {
    typealias StreamResult = Result<Response, Error>
    typealias StreamCompletion = (_ event: NetworkDataStream.ResponseEvent) -> Void

    enum State {
        case initialised
        case resumed
        case suspended
        case cancelled
        case finished
    }

    struct Response {
        let response: HTTPURLResponse?
        let data: Data?
    }

    enum ResponseEvent {
        case stream(StreamResult)
        case complete(Completion)
        case response(HTTPURLResponse?)
    }

    struct Completion {
        let response: HTTPURLResponse?
        let error: Error?
    }

    private let lock = UnfairLock()
    private var streamCallback: StreamCompletion?
    private let id: UUID

    private var state: State

    var isCancelled: Bool {
        lock.withLock {
            state == .cancelled
        }
    }

    /// the underlying task of the network request
    private var task: URLSessionTask?

    var urlResponse: HTTPURLResponse? {
        lock.withLock {
            task?.response as? HTTPURLResponse
        }
    }

    init(id: UUID, underlyingQueue _: DispatchQueue) {
        self.id = id
        state = .initialised
    }

    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let task = session.dataTask(with: request)
        let shouldCancel = lock.withLock { () -> Bool in
            guard state != .cancelled, state != .finished else { return true }
            self.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
        return task
    }

    @discardableResult
    func responseStream(completion: @escaping StreamCompletion) -> Self {
        lock.withLock {
            guard state != .cancelled, state != .finished else { return }
            streamCallback = completion
        }
        return self
    }

    @discardableResult
    func resume() -> Self {
        lock.withLock {
            guard state.canBecome(.resumed) else { return }
            state = .resumed
            task?.resume()
        }
        return self
    }

    func cancel() {
        lock.withLock {
            guard state.canBecome(.cancelled) else { return }
            state = .cancelled
            streamCallback = nil
            task?.cancel()
            self.task = nil
        }
    }

    func suspend() {
        lock.withLock {
            guard state.canBecome(.suspended) else { return }
            state = .suspended
            task?.suspend()
        }
    }

    // MARK: Internal

    func didReceive(response: HTTPURLResponse?) {
        callbackIfActive()?(.response(response))
    }

    func didReceive(data: Data, response: HTTPURLResponse?) {
        let streamResponse = Response(response: response, data: data)
        callbackIfActive()?(.stream(.success(streamResponse)))
    }

    func didComplete(with error: Error?, response: HTTPURLResponse?) {
        let callback = lock.withLock { () -> StreamCompletion? in
            guard state != .cancelled else { return nil }
            state = .finished
            let callback = streamCallback
            streamCallback = nil
            task = nil
            return callback
        }
        guard let callback else { return }

        if let error {
            callback(.stream(.failure(error)))
        } else {
            callback(.complete(Completion(response: response, error: nil)))
        }
    }

    private func callbackIfActive() -> StreamCompletion? {
        lock.withLock {
            guard state != .cancelled, state != .finished else { return nil }
            return streamCallback
        }
    }
}

// MARK: Equatable & Hashable

extension NetworkDataStream: Equatable {
    static func == (lhs: NetworkDataStream, rhs: NetworkDataStream) -> Bool {
        lhs.id == rhs.id
    }
}

extension NetworkDataStream: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension NetworkDataStream.State {
    func canBecome(_ state: NetworkDataStream.State) -> Bool {
        switch (self, state) {
        case (.initialised, _):
            return true
        case (_, .initialised),
             (.cancelled, _),
             (.finished, _):
            return false
        case (.resumed, .cancelled),
             (.resumed, .suspended),
             (.suspended, .resumed),
             (.suspended, .cancelled):
            return true
        case (.suspended, .suspended),
             (.resumed, .resumed):
            return false
        case (_, .finished):
            return true
        }
    }
}
