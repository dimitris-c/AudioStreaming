//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

enum DataStreamError: Error {
    case unknown
    case sessionDeinit
}

public enum NetworkError: Error, Equatable {
    case failure(Error)
    case serverError
    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case (.failure, failure):
            return true
        case (.serverError, .serverError):
            return true
        default:
            return false
        }
    }
}

protocol StreamTaskProvider: AnyObject {
    func dataStream(for request: URLSessionTask) -> NetworkDataStream?
}

extension URLSessionConfiguration {
    static var networkingConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .avStreaming
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.shouldUseExtendedBackgroundIdleMode = true
        return configuration
    }
}

internal final class NetworkingClient {
    let session: URLSession
    weak var delegate: NetworkSessionDelegate?
    let networkQueue: DispatchQueue

    var tasksLock = UnfairLock()
    var tasks = BiMap<URLSessionTask, NetworkDataStream>()

    internal init(configuration: URLSessionConfiguration = .networkingConfiguration,
                  delegate: NetworkSessionDelegate = NetworkSessionDelegate(),
                  networkQueue: DispatchQueue = DispatchQueue(label: "audio.streaming.session.network.queue"))
    {
        let delegateQueue = operationQueue(underlyingQueue: networkQueue)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        self.session = session
        self.delegate = delegate
        self.networkQueue = networkQueue
        delegate.taskProvider = self
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Creates a data stream for the given `URLRequest`
    /// - parameter request: A `URLRequest` to be used for the data stream
    internal func stream(request: URLRequest) -> NetworkDataStream {
        let stream = NetworkDataStream(id: UUID(), underlyingQueue: networkQueue)
        setupRequest(stream, request: request)
        return stream
    }

    internal func remove(task: NetworkDataStream) {
        tasksLock.lock(); defer { tasksLock.unlock() }
        if !tasks.isEmpty {
            tasks[task] = nil
        }
    }

    // MARK: Private

    /// Schedules the given `NetworkDataStream` to be performed immediatelly
    /// - parameter stream: The `NetworkDataStream` object to be performed
    /// - parameter request: The `URLRequest` for the `stream`
    private func setupRequest(_ stream: NetworkDataStream, request: URLRequest) {
        tasksLock.lock(); defer { tasksLock.unlock() }
        guard !stream.isCancelled else { return }
        let task = stream.task(for: request, using: session)
        tasks[stream] = task
    }
}

// MARK: StreamTaskProvider conformance

extension NetworkingClient: StreamTaskProvider {
    internal func dataStream(for request: URLSessionTask) -> NetworkDataStream? {
        tasksLock.lock(); defer { tasksLock.unlock() }
        return tasks[request] ?? nil
    }

    internal func sessionTask(for stream: NetworkDataStream) -> URLSessionTask? {
        tasksLock.lock(); defer { tasksLock.unlock() }
        return tasks[stream] ?? nil
    }
}

// MARK: Helper

private func operationQueue(underlyingQueue: DispatchQueue) -> OperationQueue {
    let delegateQueue = OperationQueue()
    delegateQueue.qualityOfService = .default
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = underlyingQueue
    delegateQueue.name = "com.decimal.session.delegate.queue"
    return delegateQueue
}
