//
//  DispatchTimerSourceTests.swift
//  AudioStreamingTests
//
//  Created by Dimitrios Chatzieleftheriou on 25/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest
@testable import AudioStreaming

class DispatchTimerSourceTests: XCTestCase {
    let dispatchKey = DispatchSpecificKey<Int>()

    let dispatchQueue = DispatchQueue(label: "some.queue")
    var timerSource: DispatchTimerSource?

    override func setUp() {
        dispatchQueue.setSpecific(key: dispatchKey, value: 1)
        timerSource = DispatchTimerSource(interval: .milliseconds(100), queue: dispatchQueue)
    }

    override func tearDown() {
        timerSource = nil
    }

    func test_DispatchTimerSource_Can_Be_Activated_and_Suspended() {
        // starts deactivated
        XCTAssertFalse(timerSource!.isRunning)

        // when actiavated
        timerSource!.activate()
        // it should run
        XCTAssertTrue(timerSource!.isRunning)

        // when suspended
        timerSource!.suspend()
        // it should not run
        XCTAssertFalse(timerSource!.isRunning)
    }

    func test_DispatchTimerSource_Can_Add_A_Handler_ToBe_Called() {
        let expectaction = expectation(description: "fired")

        timerSource?.add {
            expectaction.fulfill()
        }
        timerSource?.activate()

        wait(for: [expectaction], timeout: 1)
        // kill the timer
        timerSource?.suspend()
    }

    func test_DispatchTimerSource_Can_Remove_Handler() {
        let expectaction = expectation(description: "fired")

        timerSource?.add {
            expectaction.fulfill()
        }
        timerSource?.activate()

        wait(for: [expectaction], timeout: 1)
        // kill the timer
        timerSource?.suspend()
        timerSource?.removeHandler()
    }

    func test_DispatchTimerSource_Can_Be_Deallocated_While_Activated() {
        // `deinit` used to resume unconditionally to balance a suspended source. When the source
        // was still activated — a pending retry whose owner is torn down — that extra resume is an
        // over-resume and libdispatch traps on it. Reaching the end of this test is the assertion.
        var source: DispatchTimerSource? = DispatchTimerSource(interval: .milliseconds(100), queue: dispatchQueue)
        source?.activate()
        XCTAssertTrue(source!.isRunning)

        source = nil
        XCTAssertNil(source)
    }

    func test_DispatchTimerSource_Repeated_Activate_And_Suspend_Stay_Balanced() {
        // Each activate/suspend must move the suspend count exactly once, no matter how often the
        // no-op path is taken.
        timerSource?.activate()
        timerSource?.activate()
        XCTAssertTrue(timerSource!.isRunning)

        timerSource?.suspend()
        timerSource?.suspend()
        XCTAssertFalse(timerSource!.isRunning)

        timerSource?.activate()
        XCTAssertTrue(timerSource!.isRunning)
        timerSource?.suspend()
    }

    func test_HandlerIsExecuted_On_The_Specified_Queue() {
        let expectaction = expectation(description: "fired")

        timerSource?.add {
            XCTAssertEqual(DispatchQueue.getSpecific(key: self.dispatchKey), 1)
            expectaction.fulfill()
        }
        timerSource?.activate()

        wait(for: [expectaction], timeout: 1)
        // kill the timer
        timerSource?.suspend()
    }
}
