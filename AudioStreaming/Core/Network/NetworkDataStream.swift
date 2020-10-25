//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class NetworkDataStream {
    typealias StreamResult = Result<StreamResponse, Error>
    typealias StreamCompletion = (_ event: NetworkDataStream.StreamEvent) -> Void

    struct StreamResponse {
        let response: HTTPURLResponse?
        let data: Data?
    }

    enum StreamEvent {
        case stream(StreamResult)
        case complete(Completion)
        case response(HTTPURLResponse?)
    }

    struct Completion {
        let response: HTTPURLResponse?
        let error: Error?
    }

    private var streamCallback: StreamCompletion?

    /// The serial queue for all internal async actions.
    private let underlyingQueue: DispatchQueue
    private let id: UUID

    /// the underlying task of the network request
    private var task: URLSessionTask?

    var urlResponse: HTTPURLResponse? {
        task?.response as? HTTPURLResponse
    }

    internal init(id: UUID, underlyingQueue: DispatchQueue) {
        self.id = id
        self.underlyingQueue = underlyingQueue
    }

    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let task = session.dataTask(with: request)
        self.task = task
        return task
    }

    @discardableResult
    func responseStream(completion: @escaping StreamCompletion) -> Self {
        streamCallback = completion
        return self
    }

    @discardableResult
    func resume() -> Self {
        underlyingQueue.async { [weak self] in
            self?.task?.resume()
        }
        return self
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: Internal

    internal func didReceive(response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let streamCallback = self.streamCallback else { return }
            streamCallback(.response(response))
        }
    }

    internal func didReceive(data: Data, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let streamCallback = self.streamCallback else { return }
            let streamResponse = StreamResponse(response: response, data: data)
            streamCallback(.stream(.success(streamResponse)))
        }
    }

    internal func didComplete(with error: Error?, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.streamCallback else { return }
            if let error = error {
                stream(.stream(.failure(error)))
            } else {
                let completion = Completion(response: response, error: error)
                stream(.complete(completion))
            }
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
