//
//  Created by Dimitrios Chatzieleftheriou on 10/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation


private let outputChannels: UInt32 = 2
struct UnitDescriptions {
    static let converter = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter,
                                                     componentSubType: kAudioUnitSubType_AUConverter,
                                                     componentManufacturer: kAudioUnitManufacturer_Apple,
                                                     componentFlags: 0,
                                                     componentFlagsMask: 0)
    
    static var output: AudioComponentDescription = {
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Output
        #if os(iOS)
        desc.componentSubType = kAudioUnitSubType_RemoteIO
        #else
        desc.componentSubType = kAudioUnitSubType_DefaultOutput
        #endif
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        return desc
    }()
    
    static var canonicalAudioStream: AudioStreamBasicDescription = {
        var bytesPerSample = UInt32(MemoryLayout<Int32>.size)
        if #available(iOS 8.0, *) {
            bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        }
        let formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
        let desc = AudioStreamBasicDescription(mSampleRate: 44100.0,
                                               mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: formatFlags,
                                               mBytesPerPacket: bytesPerSample * outputChannels,
                                               mFramesPerPacket: 1,
                                               mBytesPerFrame: bytesPerSample * outputChannels,
                                               mChannelsPerFrame: outputChannels,
                                               mBitsPerChannel: 8 * bytesPerSample,
                                               mReserved: 0)
        return desc
    }()
    
}
