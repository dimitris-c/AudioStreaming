
#if os(iOS)
import UIKit
#else
import AppKit
#endif

final class DisplayLink {

    private var displayLink: DisplayLinkPlatform?

    var isPaused: Bool = true {
        didSet {
            displayLink?.isPaused = isPaused
        }
    }

    init(onTick: @escaping (DisplayLinkFrame) -> Void) {
        displayLink = DisplayLinkPlatform()

        displayLink?.onTick = onTick
    }

    deinit {
        deactivate()
    }

    func activate() {
        displayLink?.activate()
        self.isPaused = false
    }

    func deactivate() {
        displayLink?.deactivate()
        isPaused = true
    }
}

struct DisplayLinkFrame {
    var timestamp: TimeInterval
    var duration: TimeInterval
}

#if os(iOS)
final class DisplayLinkPlatform {
    private final class DisplayLinkTarget {
        var onTick: ((DisplayLinkFrame) -> Void)?

        @objc func tick(_ link: CADisplayLink) {
            onTick?(DisplayLinkFrame(timestamp: link.timestamp, duration: link.duration))
        }
    }

    var onTick: ((DisplayLinkFrame) -> Void)?
    private var target = DisplayLinkTarget()
    var displayLink: CADisplayLink?

    var isPaused: Bool {
        get { displayLink?.isPaused ?? false }
        set { displayLink?.isPaused = newValue }
    }

    init() {
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        target.onTick = { [weak self] value in
            self?.onTick?(value)
        }
    }

    deinit {
        displayLink?.invalidate()
    }

    func activate() {
        displayLink?.invalidate()
        displayLink = nil
        displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        displayLink?.preferredFrameRateRange = .init(minimum: 6, maximum: 10)
        displayLink?.add(to: .current, forMode: .common)
    }

    func deactivate() {
        displayLink?.invalidate()
        displayLink = nil
    }
}
#else
final class DisplayLinkPlatform {

    var onTick: ((DisplayLinkFrame) -> Void)?
    var isPaused: Bool = true {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused == true {
                CVDisplayLinkStop(self.displayLink)
            } else {
                CVDisplayLinkStart(self.displayLink)
            }
        }
    }

    /// The CVDisplayLink that powers this DisplayLink instance.
    var displayLink: CVDisplayLink = {
        var dl: CVDisplayLink? = nil
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        return dl!
    }()

    init() {
        CVDisplayLinkSetOutputHandler(self.displayLink, { [weak self] (displayLink, inNow, inOutputTime, flageIn, flagsOut) -> CVReturn in
            let frame = DisplayLinkFrame(
                timestamp: inNow.pointee.timeInterval,
                duration: inOutputTime.pointee.timeInterval - inNow.pointee.timeInterval)

            DispatchQueue.main.async {
                guard self?.isPaused == false else { return }
                self?.onTick?(frame)
            }

            return kCVReturnSuccess
        })
    }

    func activate() {
        isPaused = true
    }

    func deactivate() {
        isPaused = false
    }
}

extension CVTimeStamp {
    fileprivate var timeInterval: TimeInterval {
        return TimeInterval(videoTime) / TimeInterval(self.videoTimeScale)
    }
}
#endif
