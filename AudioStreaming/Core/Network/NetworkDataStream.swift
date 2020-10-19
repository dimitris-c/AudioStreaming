//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class NetworkDataStream {
    typealias StreamResult = Result<StreamResponse, Error>
    typealias StreamCompletion = (queue: OperationQueue, event: (_ event: NetworkDataStream.StreamEvent) -> Void)
    
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
    func responseStream(on queue: OperationQueue,
                        completion: @escaping (_ event: NetworkDataStream.StreamEvent) -> Void) -> Self {
        self.streamCallback = (queue, completion)
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
        self.task?.cancel()
        self.task = nil
    }

    // MARK: Internal
    
    internal func didReceive(response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.streamCallback else { return }
            stream.queue.addOperation {
                stream.event(.response(response))
            }
        }
    }
    
    internal func didReceive(data: Data, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.streamCallback else { return }
            let operation = BlockOperation {
                let streamResponse = StreamResponse(response: response, data: data)
                stream.event(.stream(.success(streamResponse)))
            }
            stream.queue.addOperation(operation)
        }
    }
    
    internal func didComplete(with error: Error?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.streamCallback else { return }
            let operation = BlockOperation {
                if let error = error {
                    stream.event(.stream(.failure(error)))
                } else {
                    let completion = Completion(response: self.task?.response as? HTTPURLResponse,
                                                error: error)
                    stream.event(.complete(completion))
                }
            }
            if let lastOp = stream.queue.operations.last {
                operation.addDependency(lastOp)
            }
            stream.queue.addOperation(operation)
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
