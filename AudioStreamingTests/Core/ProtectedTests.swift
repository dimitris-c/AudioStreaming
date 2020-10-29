//
//  Created by Dimitrios Chatzieleftheriou on 22/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import XCTest

@testable import AudioStreaming

class ProtectedTests: XCTestCase {
    func testProtectedValuesAreAccessedSafely() {
        measure {
            let protected = Protected<Int>(0)

            DispatchQueue.concurrentPerform(iterations: 1_000_000) { _ in
                _ = protected.value
                protected.write { $0 += 1 }
            }

            XCTAssertEqual(protected.value, 1_000_000)
        }
    }

    func testThatProtectedReadAndWriteAreSafe() {
        measure {
            let initialValue = "aValue"
            let protected = Protected<String>(initialValue)

            DispatchQueue.concurrentPerform(iterations: 1000) { i in
                _ = protected.read { $0 }
                protected.write { $0 = "\(i)" }
            }

            XCTAssertNotEqual(protected.value, initialValue)
        }
    }
}
