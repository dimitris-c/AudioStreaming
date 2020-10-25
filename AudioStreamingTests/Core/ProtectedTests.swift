//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest

@testable import AudioStreaming

class ProtectedTests: XCTestCase {
    func testProtectedValuesAreAccessedSafely() {
        let initialValue = "aValue"
        let protected = Atomic<String>(wrappedValue: initialValue)

        DispatchQueue.concurrentPerform(iterations: 1000) { int in
            _ = protected.wrappedValue
            protected.write { value in
                value = "\(int)"
            }
        }

        XCTAssertNotEqual(protected.wrappedValue, initialValue)
    }

    func testThatProtectedReadAndWriteAreSafe() {
        let initialValue = "aValue"
        let protected = Atomic<String>(wrappedValue: initialValue)

        DispatchQueue.concurrentPerform(iterations: 1000) { i in
            _ = protected.read { $0 }
            protected.write { $0 = "\(i)" }
        }

        XCTAssertNotEqual(protected.wrappedValue, initialValue)
    }
}

final class ProtectedWrapperTests: XCTestCase {
    @Atomic var value = 100

    override func setUp() {
        super.setUp()

        $value.write { value in
            value = 100
        }
    }

    func testThatProjectedReadWriteAccessedSafely() {
        // Given
        let initialValue = value

        // When
        DispatchQueue.concurrentPerform(iterations: 10000) { i in
            _ = $value.read { $0 }
            $value.write { $0 = i }
        }

        // Then
        XCTAssertNotEqual(value, initialValue)
    }
}
