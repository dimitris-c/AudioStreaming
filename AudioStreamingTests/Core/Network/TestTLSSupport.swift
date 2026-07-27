import Foundation
import Security
import Network
@testable import AudioStreaming

/// Generates a throwaway CA plus server and client leaf certificates using the
/// system `openssl` (LibreSSL) binary, and imports them into Security types for
/// local mutual-TLS tests. Everything lives in a temp directory removed by
/// `cleanup()`.
struct TestCertificateBundle {
    let directory: URL
    let caCertificate: SecCertificate
    let serverIdentity: SecIdentity
    let clientCredential: URLCredential

    static let openSSLPath = "/usr/bin/openssl"

    static var isOpenSSLAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: openSSLPath)
    }

    enum GenerationError: Error {
        case openSSLFailed(args: [String], output: String)
        case pkcs12ImportFailed(OSStatus)
        case certificateLoadFailed
    }

    static func generate(password: String = "test") throws -> TestCertificateBundle {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mtls-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Certificate authority
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", "ca.key", "-out", "ca.pem", "-days", "1",
            "-subj", "/CN=AudioStreaming Test CA"
        ], in: dir)

        // Server leaf with SAN=localhost, signed by the CA
        try runOpenSSL([
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", "server.key", "-out", "server.csr",
            "-subj", "/CN=localhost"
        ], in: dir)
        try "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n"
            .write(to: dir.appendingPathComponent("server.ext"), atomically: true, encoding: .utf8)
        try runOpenSSL([
            "x509", "-req", "-in", "server.csr",
            "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
            "-out", "server.pem", "-days", "1",
            "-extfile", "server.ext"
        ], in: dir)
        try runOpenSSL([
            "pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem",
            "-certfile", "ca.pem", "-out", "server.p12",
            "-name", "server", "-passout", "pass:\(password)"
        ], in: dir)

        // Client leaf, signed by the CA
        try runOpenSSL([
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", "client.key", "-out", "client.csr",
            "-subj", "/CN=AudioStreaming Test Client"
        ], in: dir)
        try "extendedKeyUsage=clientAuth\n"
            .write(to: dir.appendingPathComponent("client.ext"), atomically: true, encoding: .utf8)
        try runOpenSSL([
            "x509", "-req", "-in", "client.csr",
            "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
            "-out", "client.pem", "-days", "1",
            "-extfile", "client.ext"
        ], in: dir)
        try runOpenSSL([
            "pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem",
            "-certfile", "ca.pem", "-out", "client.p12",
            "-name", "client", "-passout", "pass:\(password)"
        ], in: dir)

        let caCertificate = try loadCertificate(pemURL: dir.appendingPathComponent("ca.pem"))
        let serverIdentity = try loadIdentity(p12URL: dir.appendingPathComponent("server.p12"),
                                              password: password)
        let clientIdentity = try loadIdentity(p12URL: dir.appendingPathComponent("client.p12"),
                                              password: password)
        let clientCredential = URLCredential(identity: clientIdentity,
                                             certificates: nil,
                                             persistence: .forSession)

        return TestCertificateBundle(directory: dir,
                                     caCertificate: caCertificate,
                                     serverIdentity: serverIdentity,
                                     clientCredential: clientCredential)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private static func runOpenSSL(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: openSSLPath)
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GenerationError.openSSLFailed(args: args, output: output)
        }
        return output
    }

    private static func loadCertificate(pemURL: URL) throws -> SecCertificate {
        let pem = try String(contentsOf: pemURL, encoding: .utf8)
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw GenerationError.certificateLoadFailed
        }
        return cert
    }

    private static func loadIdentity(p12URL: URL, password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: p12URL)
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let array = items as? [[String: Any]],
              let identity = array.first?[kSecImportItemIdentity as String] else {
            throw GenerationError.pkcs12ImportFailed(status)
        }
        return identity as! SecIdentity
    }
}

/// A local HTTPS server that requires and verifies a client certificate against
/// the test CA, then answers any request with a minimal HTTP 200. Binds an
/// ephemeral port so parallel tests don't collide.
final class MockMutualTLSServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock.mtls.server")
    private(set) var port: UInt16 = 0

    init(serverIdentity: SecIdentity, caCertificate: SecCertificate) throws {
        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions
        guard let secIdentity = sec_identity_create(serverIdentity) else {
            throw NSError(domain: "MockMutualTLSServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
        }
        sec_protocol_options_set_local_identity(sec, secIdentity)
        sec_protocol_options_set_peer_authentication_required(sec, true)

        let ca = caCertificate
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            // Replace the default SSL policy with a basic X.509 policy so the
            // evaluation checks chain validity only, not EKU or hostname.
            let basicPolicy = SecPolicyCreateBasicX509()
            SecTrustSetPolicies(trust, basicPolicy)
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            complete(SecTrustEvaluateWithError(trust, nil))
        }, queue)

        let params = NWParameters(tls: tlsOptions)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
            let body = "ok"
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
            connection.send(content: response.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// Test-only URLSession delegate that trusts the test CA for the server-trust
/// challenge and forwards the client-certificate challenge to the shipped
/// `NetworkSessionDelegate`.
///
/// Why this exists: in a TLS handshake the client validates the server's
/// certificate BEFORE presenting its own. The shipped delegate returns
/// `.performDefaultHandling` for server-trust, which rejects a self-signed local
/// server and aborts before the client cert is ever sent. Trusting the test CA
/// here lets the handshake reach the client-cert stage, which the real delegate
/// then answers — so the shipped code path is what's under test.
final class TrustingSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private let caCertificate: SecCertificate
    private let inner: NetworkSessionDelegate

    init(caCertificate: SecCertificate, inner: NetworkSessionDelegate) {
        self.caCertificate = caCertificate
        self.inner = inner
    }

    // Session-level challenge: handles server-trust, forwards client-cert to inner.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, session: session, completionHandler: completionHandler)
    }

    // Task-level challenge: same routing — mTLS client-cert challenges arrive here.
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleChallenge(challenge, session: session, completionHandler: completionHandler)
    }

    private func handleChallenge(_ challenge: URLAuthenticationChallenge,
                                  session: URLSession,
                                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            inner.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        }
    }
}
