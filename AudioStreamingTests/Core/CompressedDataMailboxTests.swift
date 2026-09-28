import XCTest
@testable import AudioStreaming

final class CompressedDataMailboxTests: XCTestCase {
    func testManyChunksScheduleOnlyOneDrain() {
        let mailbox = makeMailbox()

        let first = mailbox.enqueue(Data([0x01]), generation: 0)
        let second = mailbox.enqueue(Data([0x02]), generation: 0)

        XCTAssertTrue(first.shouldScheduleDrain)
        XCTAssertFalse(second.shouldScheduleDrain)
        XCTAssertEqual(mailbox.bufferedByteCount, 2)
    }

    func testHighAndLowWatermarksTransitionTransportOnce() {
        let mailbox = makeMailbox()

        let first = mailbox.enqueue(Data([0x01, 0x02]), generation: 0)
        let second = mailbox.enqueue(Data([0x03, 0x04]), generation: 0)
        let third = mailbox.enqueue(Data([0x05]), generation: 0)

        XCTAssertFalse(first.shouldSuspendTransport)
        XCTAssertTrue(second.shouldSuspendTransport)
        XCTAssertFalse(third.shouldSuspendTransport)

        guard case let .data(firstData) = mailbox.next(generation: 0)
        else {
            return XCTFail("Expected buffered data")
        }

        XCTAssertFalse(mailbox.completeData(byteCount: firstData.count, generation: 0))

        guard case let .data(secondData) = mailbox.next(generation: 0) else {
            return XCTFail("Expected second buffered chunk")
        }
        XCTAssertTrue(mailbox.completeData(byteCount: secondData.count, generation: 0))
    }

    func testTerminalIsDeliveredAfterBufferedData() {
        let mailbox = makeMailbox()
        _ = mailbox.enqueue(Data([0x01]), generation: 0)
        let finish = mailbox.finish("eof", generation: 0)

        XCTAssertFalse(finish.shouldScheduleDrain)
        guard case let .data(data) = mailbox.next(generation: 0) else {
            return XCTFail("Expected data before terminal")
        }
        _ = mailbox.completeData(byteCount: data.count, generation: 0)
        guard case let .terminal(value) = mailbox.next(generation: 0) else {
            return XCTFail("Expected terminal after data")
        }
        XCTAssertEqual(value, "eof")
    }

    func testSuspendedConsumerSchedulesDrainWhenResumed() {
        let mailbox = makeMailbox()
        mailbox.suspendConsumer()

        let enqueue = mailbox.enqueue(Data([0x01]), generation: 0)

        XCTAssertFalse(enqueue.shouldScheduleDrain)
        XCTAssertTrue(mailbox.resumeConsumer())
    }

    func testResetRejectsEventsFromPreviousGeneration() {
        let mailbox = makeMailbox()
        let oldGeneration = mailbox.generation
        let newGeneration = mailbox.reset()

        let stale = mailbox.enqueue(Data([0x01]), generation: oldGeneration)
        let current = mailbox.enqueue(Data([0x02]), generation: newGeneration)

        XCTAssertFalse(stale.accepted)
        XCTAssertTrue(current.accepted)
        XCTAssertEqual(mailbox.bufferedByteCount, 1)
    }

    func testConcurrentEnqueueIsThreadSafeAndSchedulesOneDrain() {
        let mailbox = CompressedDataMailbox<String>(highWatermark: 10_000, lowWatermark: 5_000)
        let scheduledDrainCount = Atomic(0)

        DispatchQueue.concurrentPerform(iterations: 1_000) { value in
            let result = mailbox.enqueue(Data([UInt8(value % 256)]), generation: 0)
            if result.shouldScheduleDrain {
                scheduledDrainCount.write { $0 += 1 }
            }
        }

        XCTAssertEqual(mailbox.bufferedByteCount, 1_000)
        XCTAssertEqual(scheduledDrainCount.value, 1)
    }

    private func makeMailbox() -> CompressedDataMailbox<String> {
        CompressedDataMailbox(highWatermark: 4, lowWatermark: 2)
    }
}
