import Foundation
import Network

/// A minimal local HTTP/1.1 server for tests: binds an ephemeral loopback port
/// and answers every request with 200 OK and a small JSON body. Plain HTTP (no
/// TLS) so requests through the production `NetworkingClient` connect without a
/// server-trust challenge.
final class MockHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock.http.server")
    private let body: String
    private(set) var port: UInt16 = 0

    init(body: String = #"{"status":"ok"}"#) throws {
        self.body = body
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [body, weak connection] _, _, _, _ in
            guard let connection else { return }
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
            connection.send(content: response.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
