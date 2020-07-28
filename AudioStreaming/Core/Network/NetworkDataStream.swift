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
    
    private var task: URLSessionTask?
    
    // the accumulated data received from the URLSession
    private var dataReceived = Data()
    // keeps a track of the written bytes in the output stream
    private var bytesWritten: Int = 0
    
    var urlResponse: HTTPURLResponse? {
        task?.response as? HTTPURLResponse
    }
    
    // The Buffer size to read/write in the InputStream/OutputStream
    private var bufferSize: Int = 1024
    
    internal init(id: UUID,
                  underlyingQueue: DispatchQueue) {
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
    
    internal func didReceive(data: Data, response: HTTPURLResponse?) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            self.dataReceived.append(data)
            if let outputStream = self.streamState.outputStream {
                self.writeData(on: outputStream)
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
        // send completion
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
    
}

extension NetworkDataStream: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard let stream = streamState.outputStream, aStream == stream else { return }
        switch eventCode {
            case .openCompleted:
                print("output stream open completed")
            case .hasSpaceAvailable:
                writeData(on: stream)
            case .endEncountered:
                print("end encountered")
            case .errorOccurred:
                print("handle error! stop everything right?")
            default:
                break
        }
    }
    
    /// Writes the data to the outputStream
    private func writeData(on stream: OutputStream) {
        underlyingQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.dataReceived.isEmpty else { return }
            var bytes = self.dataReceived.getBytes { $0 }
            bytes += self.bytesWritten
            let dataCount = self.dataReceived.count
            // get the count of bytes to be written, restrict to maximum of `bufferSize`
            let count = (dataCount - self.bytesWritten >= self.bufferSize)
                ? self.bufferSize
                : dataCount - self.bytesWritten
            guard count > 0 else { return }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            defer { buffer.deallocate() }
            memcpy(buffer, bytes, count)
            
            let len = stream.write(buffer, maxLength: count)
            self.bytesWritten += len
        }
    }
}

// MARK: StreamEvent Extension

extension NetworkDataStream.StreamEvent {
    /// `Result` value from `StreamEvent`
    var result: Result<NetworkDataStream.StreamResponse, Error>? {
        guard case let .stream(result) = self else {
            return nil
        }
        return result
    }
    
    /// `Data` value if any
    var value: Data? {
        guard case let .success(value) = result else {
            return nil
        }
        return value.data
    }
    
    var completion: NetworkDataStream.Completion? {
        guard case let .complete(completion) = self else { return nil }
        
        return completion
    }
    
    /// `Error` value if any
    var error: Error? {
        guard case let .failure(error) = result else {
            return nil
        }
        return error
    }
    
}
