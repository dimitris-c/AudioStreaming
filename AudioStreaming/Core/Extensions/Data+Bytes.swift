//
//  Created by Dimitrios Chatzieleftheriou on 02/07/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

extension Data {
    func getBytes<Value>(_ body: (UnsafePointer<UInt8>) -> Value) -> Value {
        return withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Value in
            guard let unsafePointer = pointer.bindMemory(to: UInt8.self).baseAddress else {
                var int: UInt8 = 0
                return body(&int)
            }
            return body(unsafePointer)
        }
    }
}
