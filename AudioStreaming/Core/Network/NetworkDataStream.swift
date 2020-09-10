//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class NetworkDataStream {
    typealias StreamResult = Result<StreamResponse, Error>
    typealias StreamCompletion = (queue: DispatchQueue, event: (_ event: NetworkDataStream.StreamEvent) -> Void)
    struct StreamResponse {
        let response: HTTPURLResponse?
        let data: Data?
    }
    
    enum StreamEvent {
        case stream(Result<StreamResponse, Error>)
        case complete(Completion)
    }
    
    struct Completion {
        let response: HTTPURLResponse?
        let error: Error?
    }
    
    struct StreamState {
        var streams: StreamCompletion?
    }
    
    @Protected
    private var streamState = StreamState()
    
    private var streamCompletion: StreamCompletion?
    
    /// The serial queue for all internal async actions.
    private let underlyingQueue: DispatchQueue
    private let id: UUID
    
    /// the underlying task of the network request
    private var task: URLSessionTask?
    
    /// the expected content length of the audio, this is used to close the output stream.
    private var expectedContentLength = ExpectedContentLength.undefined
    
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
    func responseStream(on queue: DispatchQueue = .main,
                        completion: @escaping (_ event: NetworkDataStream.StreamEvent) -> Void) -> Self {
        self.streamCompletion = (queue, completion)
        return self
    }
    
    @discardableResult
    func resume() -> Self {
        self.task?.resume()
        return self
    }
    
    func cancel() {
        self.task?.cancel()
        self.task = nil
    }

    // MARK: Internal
    
    internal func didReceive(response: HTTPURLResponse?) {
        if let contentLength = response?.expectedContentLength, contentLength > 0 {
            self.expectedContentLength = .length(value: contentLength)
        }
    }
    
    internal func didReceive(data: Data, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard let stream = self.streamCompletion else { return }
            stream.queue.async {
                let streamResponse = StreamResponse(response: response, data: data)
                stream.event(.stream(.success(streamResponse)))
            }
        }
    }
    
    internal func didComplete(with error: Error?) {
        $streamState.read { state in
            underlyingQueue.async { [weak self] in
                guard let self = self else { return }
                state.streams?.queue.async {
                    if let error = error {
                        state.streams?.event(.stream(.failure(error)))
                    } else {
                        let completion = Completion(response: self.task?.response as? HTTPURLResponse,
                                                    error: error)
                        state.streams?.event(.complete(completion))
                    }
                }
            }
        }
    }
    
    fileprivate func checkEndOfFile(stream: OutputStream, writtenBytes: Int) {
        guard self.expectedContentLength != .undefined else { return }
        if let length = self.expectedContentLength.length, length == writtenBytes {

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

// MARK: - Internal Convenience

/// An enum defining the content length of a network request
internal enum ExpectedContentLength: Equatable {
    /// Content length is undefined, eg the audio stream is a live broadcast
    case undefined
    /// Content length is specified, eg the audio stream is of fixed duration
    case length(value: Int64)
    
    var isUndefined: Bool {
        self == .undefined
    }
    
    var length: Int64? {
        switch self {
            case .length(let value):
                return value
            case .undefined:
                return nil
        }
    }
}

