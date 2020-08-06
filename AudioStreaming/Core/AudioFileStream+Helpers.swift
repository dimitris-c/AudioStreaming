//
//  Created by Dimitrios Chatzieleftheriou on 12/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

@discardableResult
@inlinable
func fileStreamGetProperty<Value>(value: inout Value, fileStream streamId: AudioFileStreamID, propertyId: AudioFileStreamPropertyID) -> OSStatus {
    var (size, _) = fileStreamGetPropertyInfo(fileStream: streamId, propertyId: propertyId)
    let status = AudioFileStreamGetProperty(streamId, propertyId, &size, &value)
    guard status == noErr else {
        return status
    }
    return status
}

@inlinable
func fileStreamGetPropertyInfo(fileStream streamId: AudioFileStreamID, propertyId: AudioFileStreamPropertyID) -> (size: UInt32, status: OSStatus) {
    var valueSize: UInt32 = 0
    let status = AudioFileStreamGetPropertyInfo(streamId, propertyId, &valueSize, nil)
    guard status  == noErr else {
        return (0, status)
    }
    return (valueSize, status)
}
