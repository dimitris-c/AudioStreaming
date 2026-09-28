import XCTest
@testable import AudioStreaming

final class RemoteAudioSourceTests: XCTestCase {
    override func tearDown() {
        ControlledStreamingURLProtocol.setRequestHandler(nil)
        ControlledStreamingURLProtocol.setResponseHeaders(nil)
        super.tearDown()
    }

    func testCloseDoesNotWaitForBlockedSourceQueue() {
        let sourceQueue = DispatchQueue(label: "remote.audio.source.test.queue")
        let queueBlocked = expectation(description: "Source queue is blocked")
        let releaseQueue = DispatchSemaphore(value: 0)
        sourceQueue.async {
            queueBlocked.fulfill()
            releaseQueue.wait()
        }
        wait(for: [queueBlocked], timeout: 1)

        let source = makeSource(underlyingQueue: sourceQueue)
        let closeReturned = expectation(description: "Close returns without waiting for source queue")
        DispatchQueue.global().async {
            source.close()
            closeReturned.fulfill()
        }

        wait(for: [closeReturned], timeout: 1)
        releaseQueue.signal()
        sourceQueue.sync {}
    }

    func testAutomaticallyDetectedOnDemandContentDoesNotReconnectOnResume() {
        let sourceQueue = DispatchQueue(label: "remote.audio.source.on-demand.test.queue")
        let source = makeControlledSource(contentType: .automatic, underlyingQueue: sourceQueue)
        let initialRequests = expectation(description: "Initial probe and stream requests")
        initialRequests.expectedFulfillmentCount = 2
        let unexpectedRequest = expectation(description: "On-demand resume must not reconnect")
        unexpectedRequest.isInverted = true

        let requestCount = LockedCounter()
        ControlledStreamingURLProtocol.setRequestHandler { _ in
            let count = requestCount.increment()
            if count <= 2 {
                initialRequests.fulfill()
            } else {
                unexpectedRequest.fulfill()
            }
        }

        source.seek(at: 0)
        wait(for: [initialRequests], timeout: 2)
        sourceQueue.sync {}

        source.suspend()
        source.resume()

        wait(for: [unexpectedRequest], timeout: 0.2)
        source.close()
        sourceQueue.sync {}
    }

    func testAutomaticallyDetectedLiveContentReconnectsAtLiveEdgeOnResume() {
        let sourceQueue = DispatchQueue(label: "remote.audio.source.live.test.queue")
        let source = makeControlledSource(contentType: .automatic, underlyingQueue: sourceQueue)
        let initialRequests = expectation(description: "Initial probe and stream requests")
        initialRequests.expectedFulfillmentCount = 2
        let resumedRequests = expectation(description: "Fresh probe and stream requests after resume")
        resumedRequests.expectedFulfillmentCount = 2

        let requestCount = LockedCounter()
        ControlledStreamingURLProtocol.setResponseHeaders([
            HeaderField.contentType: "audio/mpeg",
            IcyHeaderField.icyMetaint: "1024",
            "icy-name": "Test Radio"
        ])
        ControlledStreamingURLProtocol.setRequestHandler { _ in
            let count = requestCount.increment()
            if count <= 2 {
                initialRequests.fulfill()
            } else if count <= 4 {
                resumedRequests.fulfill()
            }
        }

        source.seek(at: 0)
        wait(for: [initialRequests], timeout: 2)
        sourceQueue.sync {}

        source.suspend()
        source.resume()

        wait(for: [resumedRequests], timeout: 2)
        source.close()
        sourceQueue.sync {}
    }

    private func makeSource(underlyingQueue: DispatchQueue) -> RemoteAudioSource {
        makeSource(
            networking: NetworkingClient(configuration: .ephemeral),
            contentType: .onDemand,
            underlyingQueue: underlyingQueue
        )
    }

    private func makeControlledSource(
        contentType: AudioContentType,
        underlyingQueue: DispatchQueue
    ) -> RemoteAudioSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledStreamingURLProtocol.self]
        return makeSource(
            networking: NetworkingClient(configuration: configuration),
            contentType: contentType,
            underlyingQueue: underlyingQueue
        )
    }

    private func makeSource(
        networking: NetworkingClient,
        contentType: AudioContentType,
        underlyingQueue: DispatchQueue
    ) -> RemoteAudioSource {
        let parser = MetadataParser().eraseToAnyParser()
        return RemoteAudioSource(
            networking: networking,
            metadataStreamSource: MetadataStreamProcessor(parser: parser),
            icycastHeadersProcessor: IcycastHeadersProcessor(),
            netStatusProvider: StubNetStatusProvider(),
            retrier: Retrier(interval: .seconds(1), maxInterval: 1, underlyingQueue: underlyingQueue),
            url: URL(string: "https://example.com/audio.mp3")!,
            httpMethod: nil,
            httpBody: nil,
            contentType: contentType,
            underlyingQueue: underlyingQueue,
            httpHeaders: [:]
        )
    }
}

private final class StubNetStatusProvider: NetStatusProvider {
    var isConnected = true
    var connectionType = NetConnectionType.wifi(connected: true)

    func start(connectionChange _: @escaping (NetConnectionType) -> Void) {}
    func stop() {}
}

private final class ControlledStreamingURLProtocol: URLProtocol {
    private static let handlerLock = UnfairLock()
    private static var requestHandler: ((URLRequest) -> Void)?
    private static var responseHeaders: [String: String]?

    static func setRequestHandler(_ handler: ((URLRequest) -> Void)?) {
        handlerLock.withLock {
            requestHandler = handler
        }
    }

    static func setResponseHeaders(_ headers: [String: String]?) {
        handlerLock.withLock {
            responseHeaders = headers
        }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (handler, configuredHeaders) = Self.handlerLock.withLock {
            (Self.requestHandler, Self.responseHeaders)
        }
        handler?(request)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: configuredHeaders ?? [
                HeaderField.contentLength: "1000",
                HeaderField.contentType: "audio/mpeg",
                HeaderField.acceptRanges: "none"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {}
}

private final class LockedCounter {
    private let lock = UnfairLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
