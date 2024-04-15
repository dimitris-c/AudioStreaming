//
//  Created by Dimitris Chatzieleftheriou on 12/04/2024.
//

import UIKit

final class DisplayLink {

    private var displayLink: CADisplayLink?
    private var target = DisplayLinkTarget()

    var isPaused: Bool = true {
        didSet {
            displayLink?.isPaused = isPaused
        }
    }

    init(onTick: @escaping (CADisplayLink) -> Void) {
        target.onTick = onTick
    }

    deinit {
        deactivate()
    }

    func activate() {
        displayLink?.invalidate()
        displayLink = nil
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        displayLink?.preferredFrameRateRange = .init(minimum: 6, maximum: 10)
        displayLink?.add(to: .current, forMode: .common)
        self.isPaused = false
    }

    func deactivate() {
        isPaused = true
        displayLink?.invalidate()
        displayLink = nil
    }
}

private final class DisplayLinkTarget {
    var onTick: ((CADisplayLink) -> Void)?

    @objc func tick(_ link: CADisplayLink) {
        onTick?(link)
    }
}
