//
//  Created by Dimitrios Chatzieleftheriou on 08/06/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class DispatchTimerSource {
    var handler: (() -> Void)?
    private let timer: DispatchSourceTimer
    internal var state: SourceState = .suspended
    
    internal enum SourceState {
        case resumed
        case suspended
    }
    
    init(interval: DispatchTimeInterval, queue: DispatchQueue?) {
        self.timer = DispatchSource.makeTimerSource(flags: [], queue: queue)        
        self.timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(0))
    }
    
    deinit {
        timer.setEventHandler(handler: nil)
        timer.cancel()
        resume()
    }
    
    func add(handler: @escaping () -> Void) {
        let handler = handler
        self.timer.setEventHandler(handler: handler)
    }
    
    func removeHandler() {
        self.timer.setEventHandler(handler: nil)
    }
    
    func resume() {
        if state == .resumed { return }
        state = .resumed
        self.timer.resume()
    }
    
    func suspend() {
        if state == .suspended { return }
        state = .suspended
        self.timer.suspend()
    }
}
