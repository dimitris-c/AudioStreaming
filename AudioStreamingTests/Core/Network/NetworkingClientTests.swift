//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest
@testable import AudioStreaming

class NetworkingClientTests: XCTestCase {
    func testNetworkDataStreamDeliversDataWithoutAnIntermediateQueueHop() {
        let stream = NetworkDataStream(
            id: UUID(),
            underlyingQueue: DispatchQueue(label: "unused.network.stream.queue")
        )
        let expected = Data([0x01, 0x02])
        var received: Data?

        stream.responseStream { event in
            guard case let .stream(.success(response)) = event else { return }
            received = response.data
        }
        stream.didReceive(data: expected, response: nil)

        XCTAssertEqual(received, expected)
    }

    func testCancelledNetworkDataStreamDropsLateCallbacks() {
        let stream = NetworkDataStream(
            id: UUID(),
            underlyingQueue: DispatchQueue(label: "unused.network.stream.queue")
        )
        var callbackCount = 0

        stream.responseStream { _ in
            callbackCount += 1
        }
        stream.cancel()
        stream.didReceive(data: Data([0x01]), response: nil)
        stream.didComplete(with: nil, response: nil)

        XCTAssertEqual(callbackCount, 0)
    }

    func testRemovingAStreamMoreThanOnceIsSafe() {
        let networking = NetworkingClient(configuration: .ephemeral)
        let request = URLRequest(url: URL(string: "https://example.com/audio")!)
        let stream = networking.stream(request: request)
        let task = networking.sessionTask(for: stream)

        networking.remove(task: stream)
        networking.remove(task: stream)

        XCTAssertNotNil(task)
        XCTAssertNil(networking.sessionTask(for: stream))
        if let task {
            XCTAssertNil(networking.removeDataStream(for: task))
        }
    }

    func testCompletionCallbackCanRemoveItsOwnStream() throws {
        let delegate = NetworkSessionDelegate()
        let networking = NetworkingClient(
            configuration: .ephemeral,
            delegate: delegate
        )
        let request = URLRequest(url: URL(string: "https://example.com/audio")!)
        let stream = networking.stream(request: request)
        let task = try XCTUnwrap(networking.sessionTask(for: stream))
        stream.responseStream { _ in
            networking.remove(task: stream)
        }

        delegate.urlSession(
            networking.session,
            task: task,
            didCompleteWithError: nil
        )

        XCTAssertNil(networking.sessionTask(for: stream))
        XCTAssertNil(networking.dataStream(for: task))
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

    func testShouldStartRequestImmediatelly() {
        let networking = NetworkingClient()
        let url = URL(string: "https://httpbun.com/get")!
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

        XCTAssertEqual(responseCompletion?.response?.statusCode, 200)
        XCTAssertNotNil(responseCompletion)
        XCTAssertNotNil(receivedData)
    }
}
