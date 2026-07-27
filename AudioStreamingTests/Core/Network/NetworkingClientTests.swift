//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest
@testable import AudioStreaming

final class NetworkingClientTests: XCTestCase {
    private var server: MockHTTPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try MockHTTPServer()
        try server.start()
        XCTAssertGreaterThan(server.port, 0, "server failed to bind a port")
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        try super.tearDownWithError()
    }

    func testInitialiseCorrectly() throws {
        let networking = NetworkingClient()

        XCTAssertNotNil(networking.session.delegate)
        XCTAssert(networking.delegate === networking.session.delegate)
    }

    func testInitialiseCorrectlyWithCustomArguments() {
        let configuration = URLSessionConfiguration.default
        let delegate = NetworkSessionDelegate()
        let queue = DispatchQueue(label: "temp.queue")

        let networking = NetworkingClient(configuration: configuration,
                                          delegate: delegate,
                                          networkQueue: queue)

        XCTAssertNotNil(networking.session)
        XCTAssertTrue(networking.delegate === networking.session.delegate)
        XCTAssertTrue(networking.networkQueue == queue)
    }

    func testShouldStartRequestImmediatelly() throws {
        let networking = NetworkingClient()
        let url = URL(string: "http://127.0.0.1:\(server.port)/get")!
        let request = URLRequest(url: url)

        let expectation = self.expectation(description: "\(url)")

        var responseCompletion: NetworkDataStream.Completion?
        var receivedData: Data?

        networking.stream(request: request)
            .responseStream { event in
                switch event {
                case let .stream(result):
                    switch result {
                    case let .success(value):
                        receivedData = value.data
                    case .failure: break
                    }
                case let .complete(completion):
                    responseCompletion = completion
                    expectation.fulfill()
                case .response:
                    break
                }
            }
            .resume()

        waitForExpectations(timeout: 10, handler: nil)

        XCTAssertNotNil(responseCompletion)
        XCTAssertEqual(responseCompletion?.response?.statusCode, 200)
        XCTAssertNotNil(receivedData)
    }
}
