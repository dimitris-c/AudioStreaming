//
//  Created by Dimitrios Chatzieleftheriou on 03/08/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

extension AVAudioUnit {
    
    /// A convenient method that wraps the `AVAudioUnit.instantiate(with:options:)` method with a `Result` completion block
    ///
    /// Asynchronously creates an instance of an audio unit component, wrapped in an AVAudioUnit.
    ///
    /// - parameter description: An `AudioComponentDescription` object that defines the AudioUnit's description
    /// - parameter completion: A block that will get call once the instantiation of an AVAudioUnit will occur.
    ///
    static func createAudioUnit(with description: AudioComponentDescription,
                                completion: @escaping (Result<AVAudioUnit, Error>) -> Void) {
        AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { (audioUnit, error) in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            if let audioUnit = audioUnit {
                completion(.success(audioUnit))
            }
            else {
                completion(.failure(AudioPlayerError.audioSystemError(.playerNotFound)))
            }
        }
    }
}
