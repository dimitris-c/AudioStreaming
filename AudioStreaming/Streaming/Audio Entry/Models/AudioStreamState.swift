//
//  Created by Dimitrios Chatzieleftheriou on 25/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

final class AudioStreamState {
    var processedDataFormat: Bool = false
    var dataOffset: UInt64 = 0
    var dataByteCount: UInt64?
    var dataPacketOffset: UInt64?
    var dataPacketCount: Double = 0
    var streamFormat = AudioStreamBasicDescription()
}
