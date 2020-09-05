//
//  Created by Dimitrios Chatzieleftheriou on 07/08/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

/// An object that writes the received data from a network request to a specified `OutputStream`
final class OutputStreamWriter {
    /// The accumulated data received from the URLSession
    private var dataReceived = Data()
    /// Keeps track of the total written bytes in the output stream
    private var totalBytesWritten: Int = 0
    
    /// Write the data on the `OutputStream`
    ///
    /// - parameter stream: An `OutputStream` for the data to be written in.
    /// - parameter bufferSize: A `Int` value indicating the max buffer size to be written at a given time.
    ///
    /// - returns: An `Int` value indicating the accumulated written bytes.
    func writeData(on stream: OutputStream, bufferSize: Int) -> Int {
        guard !dataReceived.isEmpty else { return 0 }
        
        // gets the underlying byte buffer and writes to the stream
        let sliceCount = min(bufferSize, dataReceived.count)
        let slice = dataReceived[..<sliceCount]
        let written = slice.withUnsafeBytes { buffer -> Int in
            guard slice.count > 0 else { return 0 }
            // "safe" to force unwrap here as we check if the count is not 0
            let base = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return stream.write(base, maxLength: buffer.count)
        }
        // check if `stream.write` returns an error and return
        guard written > 0 else { return -1 }
        
        if dataReceived.count >= written {
            dataReceived.removeSubrange(..<written)
        }
        
        totalBytesWritten += written
        return totalBytesWritten
    }
    
    /// Stores the given data
    ///
    /// - parameter data: A `Data` object as received from a network request.
    func storeReceived(data: Data) {
        self.dataReceived.append(data)
    }

}
