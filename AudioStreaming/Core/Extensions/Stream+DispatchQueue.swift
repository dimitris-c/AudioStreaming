//
//  Created by Dimitrios Chatzieleftheriou on 09/07/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

extension InputStream {
    /// Sets the InputStream to the specified DispatchQueue
    ///
    /// - parameter queue: A `DispatchQueue` object the `InputStream` is attached to.
    func set(on queue: DispatchQueue) {
        CFReadStreamSetDispatchQueue(self, queue)
    }
    
    /// Unsets the InputStream to the specified DispatchQueue
    ///
    /// This sets the `DispatchQueue` to `nil`
    func unsetFromQueue() {
        CFReadStreamSetDispatchQueue(self, nil)
    }
    
}

extension OutputStream {
    /// Sets the OutputStream to the specified DispatchQueue
    ///
    /// - parameter queue: A `DispatchQueue` object the `OutputStream` is attached to.
    func set(on queue: DispatchQueue) {
        CFWriteStreamSetDispatchQueue(self, queue)
    }
    
    /// Unsets the OutputStream to the specified DispatchQueue
    ///
    /// This sets the `DispatchQueue` to `nil`
    func unsetFromQueue() {
        CFWriteStreamSetDispatchQueue(self, nil)
    }
    
}
