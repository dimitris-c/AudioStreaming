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
    /// Keeps tracks of the index that bytes were written in the output stream
    private var byteIndex: Int = 0
    
    /// Write the data on the `OutputStream`
    ///
    /// - parameter stream: An `OutputStream` for the data to be written in.
    /// - parameter bufferSize: A `Int` value indicating the max buffer size to be written at a given time.
    ///
    /// - returns: An `Int` value indicating the accumulated written bytes.
    func writeData(on stream: OutputStream, bufferSize: Int) -> Int {
        guard !dataReceived.isEmpty else { return 0 }
        var bytes = dataReceived.getBytes { $0 }
        /// offset the buffer by the number of written bytes
        bytes += byteIndex
        let dataCount = dataReceived.count
        // get the count of bytes to be written, restrict to maximum of `bufferSize`
        let count = (dataCount - byteIndex >= bufferSize)
            ? bufferSize
            : dataCount - byteIndex
        guard count > 0 else {
            return 0
        }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { buffer.deallocate() }
        memcpy(buffer, bytes, count)
        
        let written = stream.write(buffer, maxLength: count)
        byteIndex += written
        if written > 0 && dataReceived.count > written {
            dataReceived.removeFirst(written)
            byteIndex -= written
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
