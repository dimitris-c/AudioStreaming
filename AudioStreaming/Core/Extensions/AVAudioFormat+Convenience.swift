//
//  Created by Dimitrios Chatzieleftheriou on 06/08/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

extension AVAudioFormat {
    /// The underlying audio stream description.
    ///
    /// This exposes the `pointee` value of the `UsafePointer<AudioStreamBasicDescription>`
    public var basicStreamDescription: AudioStreamBasicDescription {
        return streamDescription.pointee
    }
}
