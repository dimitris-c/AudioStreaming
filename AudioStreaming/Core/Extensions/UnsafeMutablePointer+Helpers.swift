//
//  Created by Dimitrios Chatzieleftheriou on 29/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

extension UnsafeMutablePointer where Pointee == UInt8 {
    static func uint8pointer(of size: Int) -> UnsafeMutablePointer<UInt8> {
        let alignment = MemoryLayout<UInt8>.alignment
        return UnsafeMutableRawPointer
            .allocate(byteCount: size, alignment: alignment)
            .bindMemory(to: UInt8.self, capacity: size)
    }
}

extension UnsafeMutableRawPointer {
    func to<Object: AnyObject>(type: Object.Type) -> Object {
        return Unmanaged<Object>.fromOpaque(self).takeUnretainedValue()
    }
    
    static func from<Object: AnyObject>(object: Object) -> UnsafeMutableRawPointer {
        return Unmanaged<Object>.passUnretained(object).toOpaque()
    }
}
