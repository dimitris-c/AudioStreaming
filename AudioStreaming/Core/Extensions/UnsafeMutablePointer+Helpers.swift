//
//  Created by Dimitrios Chatzieleftheriou on 29/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

extension UnsafeMutableRawPointer {
    /// Converts an UnsafeMutableRawPointer to the given Object type 
    func to<Object: AnyObject>(type: Object.Type) -> Object {
        return Unmanaged<Object>.fromOpaque(self).takeUnretainedValue()
    }
    /// Converts the given object to an UnsafeMutableRawPointer
    static func from<Object: AnyObject>(object: Object) -> UnsafeMutableRawPointer {
        return Unmanaged<Object>.passUnretained(object).toOpaque()
    }
}
