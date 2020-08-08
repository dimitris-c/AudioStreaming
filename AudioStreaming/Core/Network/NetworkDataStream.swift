//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class NetworkDataStream: NSObject {
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
        var outputStream: OutputStream?
        var streams: StreamCompletion?
    }
    
    @Protected
    private var streamState = StreamState()
    
    /// The serial queue for all internal async actions.
    private let underlyingQueue: DispatchQueue
    private let id: UUID
    
    /// the underlying task of the network request
    private var task: URLSessionTask?
    
    private let outputStreamWriter: OutputStreamWriter
    
    /// the expected content length of the audio, this is used to close the output stream.
    private var expectedContentLength = ExpectedContentLength.undefined
    
    var urlResponse: HTTPURLResponse? {
        task?.response as? HTTPURLResponse
    }
    
    // The Buffer size to read/write in the InputStream/OutputStream
    private var bufferSize: Int = 1024
    
    internal init(id: UUID, underlyingQueue: DispatchQueue) {
        self.id = id
        self.underlyingQueue = underlyingQueue
        self.outputStreamWriter = OutputStreamWriter()
    }
    
    func task(for request: URLRequest, using session: URLSession) -> URLSessionTask {
        let task = session.dataTask(with: request)
        self.task = task
        return task
    }
    
    @discardableResult
    func responseStream(on queue: DispatchQueue = .main,
                        completion: @escaping (_ event: NetworkDataStream.StreamEvent) -> Void) -> Self {
        $streamState.write { state in
            state.streams = (queue, completion)
        }
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
        $streamState.write { state in
            state.outputStream?.delegate = nil
            state.outputStream?.unsetFromQueue()
            state.outputStream?.close()
            state.outputStream = nil
        }
    }
    
    func asInputStream(bufferSize: Int = 1024) -> InputStream? {
        var inputStream: InputStream?
        self.bufferSize = bufferSize
        $streamState.write { state in
            Stream.getBoundStreams(withBufferSize: bufferSize,
                                   inputStream: &inputStream,
                                   outputStream: &state.outputStream)
            state.outputStream?.delegate = self
            state.outputStream?.set(on: underlyingQueue)
            state.outputStream?.open()
        }
        
        underlyingQueue.async { [weak self] in
            self?.resume()
        }
        return inputStream
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
            self.outputStreamWriter.storeReceived(data: data)
            if let outputStream = self.streamState.outputStream, outputStream.hasSpaceAvailable {
                let writtenBytes = self.outputStreamWriter.writeData(on: outputStream, bufferSize: self.bufferSize)
                self.checkEndOfFile(stream: outputStream, writtenBytes: writtenBytes)
            }
        }
        $streamState.read { state in
            underlyingQueue.async {
                state.streams?.queue.async {
                    let streamResponse = StreamResponse(response: response, data: data)
                    state.streams?.event(.stream(.success(streamResponse)))
                }
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
            stream.close()
            stream.unsetFromQueue()
        }
    }
    
}

extension NetworkDataStream: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard let stream = streamState.outputStream, aStream == stream else { return }
        switch eventCode {
            case .openCompleted:
                Logger.debug("output stream open completed", category: .networking)
            case .hasSpaceAvailable:
                underlyingQueue.async { [weak self] in
                    guard let self = self else { return }
                    let writtenBytes = self.outputStreamWriter.writeData(on: stream, bufferSize: self.bufferSize)
                    self.checkEndOfFile(stream: stream, writtenBytes: writtenBytes)
                }
            case .errorOccurred:
                Logger.debug("handle error! stop everything right?", category: .networking)
            default:
                break
        }
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

