import Network
import XCTest
@testable import AudioStreaming

/// Resuming a stream from a server without range support after the connection broke
final class RemoteAudioSourceResumeTests: XCTestCase {
    private var server: NoRangeHTTPServer!
    private var networking: NetworkingClient!

    override func tearDown() {
        server?.stop()
        server = nil
        networking = nil
        super.tearDown()
    }

    func testResumeDropsAlreadyReadBytesOfSameContent() throws {
        let payload = Self.randomData(count: 100_000)
        server = try NoRangeHTTPServer { _ in payload }
        server.cutFirstStreamAfter = 40000

        let received = try readStream()

        XCTAssertEqual(server.streamRequestCount, 2)
        XCTAssertEqual(received.count, payload.count)
        XCTAssertEqual(received, payload)
    }

    func testResumePlaysDifferentContentFromItsStart() throws {
        let first = Self.randomData(count: 100_000)
        let second = Self.randomData(count: 60000)
        server = try NoRangeHTTPServer { index in index == 0 ? first : second }
        server.cutFirstStreamAfter = 40000

        let received = try readStream()

        XCTAssertEqual(server.streamRequestCount, 2)
        XCTAssertEqual(received, first.prefix(40000) + second)
    }

    // MARK: - Helpers

    private func readStream() throws -> Data {
        try server.start()
        networking = NetworkingClient()
        let queue = DispatchQueue(label: "remote.audio.source.test")
        let url = URL(string: "http://127.0.0.1:\(server.port)/song.mp3")!
        let source = RemoteAudioSource(networking: networking,
                                       metadataStreamSource: MetadataStreamProcessor(parser: MetadataParser().eraseToAnyParser()),
                                       icycastHeadersProcessor: IcycastHeadersProcessor(),
                                       netStatusProvider: ConnectedNetStatusProvider(),
                                       retrier: Retrier(interval: .milliseconds(100), maxInterval: 1, underlyingQueue: nil),
                                       url: url,
                                       httpMethod: nil,
                                       httpBody: nil,
                                       underlyingQueue: queue,
                                       httpHeaders: [:])
        let delegate = CollectingSourceDelegate()
        delegate.finished = expectation(description: "end of file")
        source.delegate = delegate
        queue.async { source.seek(at: 0) }
        wait(for: [delegate.finished!], timeout: 10)
        source.close()
        return delegate.data
    }

    private static func randomData(count: Int) -> Data {
        Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255) })
    }
}

private final class ConnectedNetStatusProvider: NetStatusProvider {
    var isConnected: Bool { true }
    var connectionType: NetConnectionType { .wifi(connected: true) }
    func start(connectionChange _: @escaping (NetConnectionType) -> Void) {}
    func stop() {}
}

private final class CollectingSourceDelegate: AudioStreamSourceDelegate {
    private let lock = UnfairLock()
    private var _data = Data()
    var finished: XCTestExpectation?

    var data: Data { lock.withLock { _data } }

    func dataAvailable(source _: CoreAudioStreamSource, data: Data) {
        lock.withLock { _data.append(data) }
    }

    func errorOccurred(source _: CoreAudioStreamSource, error: Error) {
        XCTFail("unexpected error: \(error)")
    }

    func endOfFileOccurred(source _: CoreAudioStreamSource) {
        finished?.fulfill()
    }

    func metadataReceived(data _: [String: String]) {}
}

/// Answers every request with 200 OK and the full body, ignoring `Range` headers.
/// The first request without a `Range` header (the audio stream) can be cut off after a number of bytes.
private final class NoRangeHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "no.range.http.server")
    private let bodyForStreamRequest: (Int) -> Data
    private(set) var port: UInt16 = 0
    private(set) var streamRequestCount = 0
    var cutFirstStreamAfter: Int?

    init(bodyForStreamRequest: @escaping (Int) -> Data) throws {
        self.bodyForStreamRequest = bodyForStreamRequest
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] request, _, _, _ in
            guard let self, let request else { return }
            let isRangeRequest = String(decoding: request, as: UTF8.self).lowercased().contains("\r\nrange:")
            var body = self.bodyForStreamRequest(self.streamRequestCount)
            if !isRangeRequest {
                self.streamRequestCount += 1
            }
            let header = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: audio/mpeg\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n"
            if !isRangeRequest, self.streamRequestCount == 1, let cut = self.cutFirstStreamAfter {
                body = body.prefix(cut)
            }
            connection.send(content: Data(header.utf8) + body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
