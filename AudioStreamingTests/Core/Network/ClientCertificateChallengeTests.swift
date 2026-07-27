import XCTest
@testable import AudioStreaming

final class ClientCertificateChallengeTests: XCTestCase {
    private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func makeChallenge(authenticationMethod: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "localhost", port: 443, protocol: "https",
                                       realm: nil, authenticationMethod: authenticationMethod)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                          previousFailureCount: 0, failureResponse: nil,
                                          error: nil, sender: NoopChallengeSender())
    }

    private func respond(_ delegate: NetworkSessionDelegate,
                         to challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        var disposition: URLSession.AuthChallengeDisposition!
        var credential: URLCredential?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { d, c in
            disposition = d
            credential = c
        }
        return (disposition, credential)
    }

    func test_clientCertificateChallenge_usesProvidedCredential() {
        let expected = URLCredential(user: "u", password: "p", persistence: .forSession)
        let delegate = NetworkSessionDelegate()
        delegate.clientCertificateProvider = { _ in expected }

        let (disposition, credential) = respond(delegate,
            to: makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate))

        XCTAssertEqual(disposition, .useCredential)
        XCTAssertTrue(credential === expected)
    }

    func test_clientCertificateChallenge_providerReturnsNil_fallsBackToDefault() {
        let delegate = NetworkSessionDelegate()
        delegate.clientCertificateProvider = { _ in nil }

        let (disposition, credential) = respond(delegate,
            to: makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func test_noProvider_fallsBackToDefault() {
        let delegate = NetworkSessionDelegate()

        let (disposition, credential) = respond(delegate,
            to: makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func test_serverTrustChallenge_doesNotConsultProvider() {
        var providerCalled = false
        let delegate = NetworkSessionDelegate()
        delegate.clientCertificateProvider = { _ in
            providerCalled = true
            return URLCredential(user: "u", password: "p", persistence: .forSession)
        }

        let (disposition, credential) = respond(delegate,
            to: makeChallenge(authenticationMethod: NSURLAuthenticationMethodServerTrust))

        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
        XCTAssertFalse(providerCalled)
    }
}
