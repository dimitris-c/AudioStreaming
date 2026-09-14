import XCTest
import Security
@testable import AudioStreaming

final class MutualTLSIntegrationTests: XCTestCase {
    private var bundle: TestCertificateBundle!
    private var server: MockMutualTLSServer!

    override func setUpWithError() throws {
        try XCTSkipUnless(TestCertificateBundle.isOpenSSLAvailable,
                          "openssl not available at /usr/bin/openssl")
        bundle = try TestCertificateBundle.generate()
        server = try MockMutualTLSServer(serverIdentity: bundle.serverIdentity,
                                         caCertificate: bundle.caCertificate)
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server failed to bind a port")
    }

    override func tearDownWithError() throws {
        server?.stop()
        bundle?.cleanup()
    }

    func test_certificateBundle_importsIdentities() throws {
        XCTAssertNotNil(bundle.clientCredential.identity)
    }

    func test_requestSucceeds_whenClientCertificateProvided() throws {
        let inner = NetworkSessionDelegate()
        let credential = bundle.clientCredential
        inner.clientCertificateProvider = { _ in credential }
        let delegate = TrustingSessionDelegate(caCertificate: bundle.caCertificate, inner: inner)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://localhost:\(server.port)/")!
        let done = expectation(description: "request completes")
        var statusCode: Int?
        var body: String?
        var requestError: Error?
        session.dataTask(with: url) { data, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            body = data.flatMap { String(data: $0, encoding: .utf8) }
            requestError = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)

        XCTAssertNil(requestError)
        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual(body, "ok")
    }

    func test_requestFails_whenClientCertificateMissing() throws {
        let inner = NetworkSessionDelegate()
        inner.clientCertificateProvider = { _ in nil }
        let delegate = TrustingSessionDelegate(caCertificate: bundle.caCertificate, inner: inner)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://localhost:\(server.port)/")!
        let done = expectation(description: "request completes")
        var statusCode: Int?
        var requestError: Error?
        session.dataTask(with: url) { _, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode
            requestError = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)

        XCTAssertNotNil(requestError, "handshake should fail without a client certificate")
        XCTAssertNotEqual(statusCode, 200)
    }
}
