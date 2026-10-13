import Network
import XCTest
@testable import AudioStreaming

final class RemoteAudioSourceRetryTests: XCTestCase {
    private var server: DroppingStreamServer!
    private var source: RemoteAudioSource!
    private var delegate: SourceDelegateSpy!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try DroppingStreamServer(refuseWindow: 1.5)
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server failed to bind a port")
    }

    override func tearDownWithError() throws {
        source?.close()
        source = nil
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    /// A stream drops mid-body and the first reconnect fails too: the source has to keep retrying
    /// until a later reconnect succeeds, and deliver that connection's audio.
    func test_Source_Keeps_Retrying_When_The_First_Reconnect_Fails() throws {
        let resumed = expectation(description: "audio from a reconnect after the failed one")
        delegate = SourceDelegateSpy(onData: { data in
            if data.contains(DroppingStreamServer.laterStreamByte) { resumed.fulfill() }
        })
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/live.mp3"))
        source = RemoteAudioSource(networking: NetworkingClient(),
                                   metadataStreamSource: MetadataStreamProcessor(parser: MetadataParser().eraseToAnyParser()),
                                   icycastHeadersProcessor: IcycastHeadersProcessor(),
                                   netStatusProvider: ConnectedNetStatusProvider(),
                                   retrier: Retrier(interval: .seconds(1), maxInterval: 5, underlyingQueue: nil),
                                   url: url,
                                   httpMethod: nil,
                                   httpBody: nil,
                                   underlyingQueue: DispatchQueue(label: "remote.audio.source.retry.tests"),
                                   httpHeaders: [:])
        source.delegate = delegate

        source.seek(at: 0)

        wait(for: [resumed], timeout: 10)
        XCTAssertGreaterThan(server.refusedConnections, 0, "the first reconnect was expected to fail")
    }
}

// MARK: - Helpers

private final class ConnectedNetStatusProvider: NetStatusProvider {
    var isConnected: Bool { true }
    var connectionType: NetConnectionType { .wifi(connected: true) }
    func start(connectionChange _: @escaping (NetConnectionType) -> Void) {}
    func stop() {}
}

private final class SourceDelegateSpy: AudioStreamSourceDelegate {
    private let onData: (Data) -> Void

    init(onData: @escaping (Data) -> Void) {
        self.onData = onData
    }

    func dataAvailable(source _: CoreAudioStreamSource, data: Data) { onData(data) }
    func errorOccurred(source _: CoreAudioStreamSource, error _: Error) {}
    func endOfFileOccurred(source _: CoreAudioStreamSource) {}
    func metadataReceived(data _: [String: String]) {}
}

/// A loopback HTTP server that behaves like a live stream on a flaky network: the first stream
/// connection sends some audio and is cut mid-body, every connection in the `refuseWindow` after
/// that is closed before a response, and connections after the window are served again.
/// The first stream's body is filled with `firstStreamByte`, every later one with `laterStreamByte`.
private final class DroppingStreamServer {
    static let firstStreamByte: UInt8 = 0x01
    static let laterStreamByte: UInt8 = 0x02

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dropping.stream.server")
    private let refuseWindow: TimeInterval
    private var droppedAt: Date?
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0
    private var _refusedConnections = 0
    var refusedConnections: Int { queue.sync { _refusedConnections } }

    init(refuseWindow: TimeInterval) throws {
        self.refuseWindow = refuseWindow
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
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        if let droppedAt, Date().timeIntervalSince(droppedAt) < refuseWindow {
            _refusedConnections += 1
            connection.cancel()
            return
        }
        let isRangeProbe = request.range(of: "\r\nRange:", options: .caseInsensitive) != nil
        let isFirstStream = droppedAt == nil && !isRangeProbe
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: audio/mpeg\r\n"
            + "Content-Length: 100000000\r\n\r\n"
        var response = Data(header.utf8)
        let fill = droppedAt == nil ? Self.firstStreamByte : Self.laterStreamByte
        response.append(Data(repeating: fill, count: 4096))
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] _ in
            guard isFirstStream, let self, let connection else { return }
            // Closing well short of Content-Length is a dropped connection to URLSession.
            self.droppedAt = Date()
            connection.cancel()
        })
    }
}
