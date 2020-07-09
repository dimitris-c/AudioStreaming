//
//  Stream+DispatchQueue.swift
//  AudioStreaming
//
//  Created by Dimitrios Chatzieleftheriou on 09/07/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

extension InputStream {
    
    func set(on queue: DispatchQueue) {
        CFReadStreamSetDispatchQueue(self, queue)
    }
    
    func unsetFromQueue() {
        CFReadStreamSetDispatchQueue(self, nil)
    }
    
}

extension OutputStream {
    func set(on queue: DispatchQueue) {
        CFWriteStreamSetDispatchQueue(self, queue)
    }
    
    func unsetFromQueue() {
        CFWriteStreamSetDispatchQueue(self, nil)
    }
    
}
