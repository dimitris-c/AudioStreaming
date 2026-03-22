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
    case serverError(HTTPResponseDetails)
    case missingData

    public static func == (lhs: NetworkError, rhs: NetworkError) -> Bool {
        switch (lhs, rhs) {
        case let (.failure(lhsError), .failure(rhsError)):
            return compareErrors(lhsError, rhsError)
        case let (.serverError(lhsDetails), .serverError(rhsDetails)):
            return lhsDetails == rhsDetails
        case (.missingData, .missingData):
            return true
        default:
            return false
        }
    }
}

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .failure(error):
            let nsError = error as NSError
            return "\(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
        case let .serverError(details):
            return details.localizedDescription
        case .missingData:
            return "Missing audio data from network stream"
        }
    }
}

public struct HTTPResponseDetails: Equatable, Sendable {
    public let statusCode: Int
    public let url: String?
    public let contentType: String?
    public let headers: [String: String]
    public let bodySnippet: String?

    init(response: HTTPURLResponse, bodySnippet: String? = nil) {
        statusCode = response.statusCode
        url = response.url?.absoluteString
        contentType = response.value(forHTTPHeaderField: "Content-Type")
        headers = response.allHeaderFields.reduce(into: [:]) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        self.bodySnippet = bodySnippet
    }

    func appendingBodySnippet(_ bodySnippet: String?) -> HTTPResponseDetails {
        HTTPResponseDetails(
            statusCode: statusCode,
            url: url,
            contentType: contentType,
            headers: headers,
            bodySnippet: bodySnippet ?? self.bodySnippet
        )
    }

    private init(
        statusCode: Int,
        url: String?,
        contentType: String?,
        headers: [String: String],
        bodySnippet: String?
    ) {
        self.statusCode = statusCode
        self.url = url
        self.contentType = contentType
        self.headers = headers
        self.bodySnippet = bodySnippet
    }

    public var localizedDescription: String {
        var parts = ["HTTP server error \(statusCode)"]
        if let contentType, !contentType.isEmpty {
            parts.append("contentType=\(contentType)")
        }
        if let url, !url.isEmpty {
            parts.append("url=\(url)")
        }
        if let bodySnippet, !bodySnippet.isEmpty {
            parts.append("bodySnippet=\(bodySnippet)")
        }
        return parts.joined(separator: " ")
    }
}

private func compareErrors(_ lhs: Error?, _ rhs: Error?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        let lhsNSError = lhs as NSError
        let rhsNSError = rhs as NSError
        return lhsNSError.domain == rhsNSError.domain &&
            lhsNSError.code == rhsNSError.code
    default:
        return false
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

final class NetworkingClient {
    let session: URLSession
    weak var delegate: NetworkSessionDelegate?
    let networkQueue: DispatchQueue

    var tasksLock = UnfairLock()
    var tasks = BiMap<URLSessionTask, NetworkDataStream>()

    init(configuration: URLSessionConfiguration = .networkingConfiguration,
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
    func stream(request: URLRequest) -> NetworkDataStream {
        let stream = NetworkDataStream(id: UUID(), underlyingQueue: networkQueue)
        setupRequest(stream, request: request)
        return stream
    }

    func remove(task: NetworkDataStream) {
        tasksLock.withLock {
            if !tasks.isEmpty {
                tasks[task] = nil
            }
        }
    }

    @discardableResult
    func task(request: URLRequest, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request) { data, _, error in
            if let error {
                completion(Result<Data, Error>.failure(error))
                return
            }
            if let data {
                completion(Result<Data, Error>.success(data))
            }
        }
        task.resume()
        return task
    }

    // MARK: Private

    /// Schedules the given `NetworkDataStream` to be performed immediately
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
    func dataStream(for request: URLSessionTask) -> NetworkDataStream? {
        tasksLock.withLock {
            tasks[request] ?? nil
        }
    }

    func sessionTask(for stream: NetworkDataStream) -> URLSessionTask? {
        tasksLock.withLock {
            tasks[stream] ?? nil
        }
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
