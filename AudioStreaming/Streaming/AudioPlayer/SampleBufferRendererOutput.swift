//
//  SampleBufferRendererOutput.swift
//  AudioStreaming
//

import AVFoundation
import CoreMedia
import OSLog

/// Plays the manually rendered output of the audio engine through an `AVSampleBufferAudioRenderer`
/// driven by an `AVSampleBufferRenderSynchronizer`, instead of an output audio unit.
///
/// Audio played this way takes part in AirPlay 2, including multi-room playback chosen in the
/// system route picker (together with the `.longFormAudio` route sharing policy). An output audio
/// unit is not routed to AirPlay devices picked there on Mac Catalyst.
///
/// The renderer is fed ahead of time, so everything rendered by the engine is heard
/// `bufferedSeconds` later. `AudioPlayer` compensates its progress and its delegate callbacks.
///
/// Threading: all control methods are non-blocking. They record the request under a lock and
/// apply it on the internal queue, which is also the queue that renders. The render function may
/// call back into `AudioPlayer` (which synchronously uses its serialization queue), so this type
/// must never wait for the internal queue from the caller's thread.
final class SampleBufferRendererOutput {
    /// Renders `frameCount` frames into `ioData`; returns the frames rendered and how many of them are
    /// audio content (counted as played by `AudioPlayer`) rather than silence padding.
    typealias RenderFunction = (_ frameCount: UInt32, _ ioData: UnsafeMutablePointer<AudioBufferList>)
        -> (rendered: UInt32, content: UInt32)

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "streaming.renderer.output", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    /// Held while the engine renders, see `waitForRenderToFinish()`
    private let renderLock = NSLock()

    private let render: RenderFunction
    private let format: AVAudioFormat
    private let formatDescription: CMAudioFormatDescription
    private let sampleRate: Int32
    private let bytesPerFrame: UInt32
    private let framesPerBuffer: AVAudioFrameCount = 4096
    private let renderBuffer: AVAudioPCMBuffer
    /// Upper bound of audio enqueued ahead of what is heard.
    private let maxBufferedSeconds: Double
    /// Audio enqueued before the synchronizer clock starts after a flush.
    private let prerollSeconds: Double = 0.1
    /// Silence (no audio content yet, e.g. waiting for data) is enqueued only this far ahead, so the
    /// audio that arrives later is not queued behind seconds of silence.
    private let maxBufferedSilenceSeconds: Double = 0.2

    /// Guards the requested state below, `enqueuedEndSeconds` and `contentTimeline`.
    private let lock = NSLock()
    private var wantsRunning = false
    private var pendingFlush = false
    private var pendingDrainStop = false
    private var enqueuedEndSeconds: Double = 0
    /// Enqueued buffers not completely heard yet, with the content frames each one holds
    private var contentTimeline = [(start: Double, end: Double, contentFrames: Int64)]()
    private var isShutDown = false

    // Only accessed on `queue`
    private var timer: DispatchSourceTimer?
    private var nextFrame: Int64 = 0
    private var startFrame: Int64 = 0
    private var clockStarted = false
    private var isRateRunning = false
    private var drainGeneration = 0
    private var lastClockRestart = Date.distantPast
    /// Enqueued buffers that might not have been heard yet, re-enqueued after an automatic flush.
    private var history = [CMSampleBuffer]()
    private var observers = [NSObjectProtocol]()

    init?(format: AVAudioFormat, maxBufferedSeconds: Double, render: @escaping RenderFunction) {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description,
              let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)
        else {
            Logger.audioRendering.error("renderer output: cannot create format description (\(status))")
            return nil
        }
        self.format = format
        self.formatDescription = description
        self.renderBuffer = renderBuffer
        self.sampleRate = Int32(format.sampleRate)
        self.bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        self.maxBufferedSeconds = max(0.5, maxBufferedSeconds)
        self.render = render

        queue.setSpecific(key: queueKey, value: ())
        synchronizer.addRenderer(renderer)
        observeRenderer()
    }

    deinit {
        shutdown()
    }

    // MARK: Public controls

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    var isMuted: Bool {
        get { renderer.isMuted }
        set { renderer.isMuted = newValue }
    }

    /// Seconds of audio content that were rendered (and counted as played by `AudioPlayer`)
    /// but not heard yet. Silence padding (waiting for data) is not included.
    var unheardContentSeconds: Double {
        let current = synchronizer.currentTime().seconds
        guard current.isFinite else { return 0 }
        let frames: Double = lock.withLock {
            var frames: Double = 0
            for chunk in contentTimeline where chunk.end > current {
                if chunk.start >= current {
                    frames += Double(chunk.contentFrames)
                } else {
                    let unheardPart = (chunk.end - current) / (chunk.end - chunk.start)
                    frames += Double(chunk.contentFrames) * unheardPart
                }
            }
            return frames
        }
        return frames / Double(sampleRate)
    }

    /// Seconds until the audio enqueued so far is heard (including silence padding).
    var bufferedSeconds: Double {
        let enqueuedEnd = lock.withLock { enqueuedEndSeconds }
        let current = synchronizer.currentTime().seconds
        guard current.isFinite else { return 0 }
        return max(0, enqueuedEnd - current)
    }

    /// Starts or resumes rendering and playback.
    func start() {
        lock.withLock {
            wantsRunning = true
            pendingDrainStop = false
        }
        queue.async { [weak self] in self?.applyStart() }
    }

    /// Pauses playback, keeping the enqueued audio for resuming.
    func pause() {
        lock.withLock { wantsRunning = false }
        queue.async { [weak self] in self?.applyPause() }
    }

    /// Drops all enqueued audio (seek, new item). The clock restarts with the next `start()`.
    func flush() {
        lock.withLock {
            pendingFlush = true
            enqueuedEndSeconds = 0
            contentTimeline.removeAll()
        }
        queue.async { [weak self] in self?.applyFlushIfNeeded() }
    }

    /// Stops playback. With `drain`, the audio already enqueued plays out first (end of queue).
    func stop(drain: Bool) {
        if drain {
            lock.withLock {
                wantsRunning = false
                pendingDrainStop = true
            }
            queue.async { [weak self] in self?.applyDrainStop() }
        } else {
            lock.withLock { wantsRunning = false }
            flush()
            queue.async { [weak self] in self?.applyPause() }
        }
    }

    /// Stops everything. Called on deinit of the player.
    func shutdown() {
        let alreadyShutDown = lock.withLock {
            let value = isShutDown
            isShutDown = true
            wantsRunning = false
            return value
        }
        guard !alreadyShutDown else { return }
        let stopOnQueue = { [self] in
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            stopTimer()
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
        }
        // wait for a render in progress: the player frees the render buffers right after this
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync(execute: stopOnQueue)
        }
    }

    /// Waits until a render that is already running has finished, at most a short moment.
    ///
    /// Call it after `pause()`/`stop(drain:)`, which prevent new renders, before resetting or stopping
    /// the engine. The wait is bounded: the render can call back into the player, which may be
    /// waiting here, and must not deadlock.
    func waitForRenderToFinish() {
        if renderLock.lock(before: Date().addingTimeInterval(0.25)) {
            renderLock.unlock()
        }
    }

    // MARK: Applying requests (on queue)

    private func applyStart() {
        dispatchPrecondition(condition: .onQueue(queue))
        applyFlushIfNeeded()
        guard lock.withLock({ wantsRunning && !isShutDown }) else { return }
        drainGeneration += 1
        if clockStarted, !isRateRunning {
            synchronizer.rate = 1
            isRateRunning = true
        }
        startTimerIfNeeded()
        feed()
    }

    private func applyPause() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !lock.withLock({ wantsRunning }) else { return }
        stopTimer()
        if isRateRunning {
            synchronizer.rate = 0
            isRateRunning = false
        }
    }

    private func applyFlushIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        let flush = lock.withLock {
            let value = pendingFlush
            pendingFlush = false
            return value
        }
        guard flush else { return }
        drainGeneration += 1
        synchronizer.setRate(0, time: .zero)
        isRateRunning = false
        clockStarted = false
        renderer.flush()
        history.removeAll()
        nextFrame = 0
        startFrame = 0
        lock.withLock {
            enqueuedEndSeconds = 0
            contentTimeline.removeAll()
        }
    }

    private func applyDrainStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard lock.withLock({ pendingDrainStop }) else { return }
        stopTimer()
        drainGeneration += 1
        let generation = drainGeneration
        let remaining = bufferedSeconds
        Logger.audioRendering.info("renderer output: draining \(remaining, format: .fixed(precision: 2)) s before stopping")
        queue.asyncAfter(deadline: .now() + remaining + 0.05) { [weak self] in
            guard let self, self.drainGeneration == generation else { return }
            guard self.lock.withLock({ self.pendingDrainStop }) else { return }
            self.lock.withLock { self.pendingDrainStop = false }
            self.synchronizer.rate = 0
            self.isRateRunning = false
        }
    }

    // MARK: Feeding (on queue)

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.feed() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func feed() {
        dispatchPrecondition(condition: .onQueue(queue))
        applyFlushIfNeeded()
        guard lock.withLock({ wantsRunning && !isShutDown && !pendingFlush }) else { return }

        while renderer.isReadyForMoreMediaData, bufferedSeconds < maxBufferedSeconds {
            guard lock.withLock({ wantsRunning && !pendingFlush }) else { break }
            guard let (sampleBuffer, contentFrames) = renderNextSampleBuffer() else { break }
            renderer.enqueue(sampleBuffer)
            history.append(sampleBuffer)
            if contentFrames == 0, bufferedSeconds >= maxBufferedSilenceSeconds {
                // no audio yet: keep the silence close to real time
                break
            }
            if !clockStarted {
                let enqueuedSeconds = Double(nextFrame - startFrame) / Double(sampleRate)
                if enqueuedSeconds >= prerollSeconds {
                    synchronizer.setRate(1, time: CMTime(value: startFrame, timescale: sampleRate))
                    clockStarted = true
                    isRateRunning = true
                }
            }
        }
        pruneHistory()
    }

    private func renderNextSampleBuffer() -> (CMSampleBuffer, contentFrames: UInt32)? {
        renderBuffer.frameLength = framesPerBuffer
        let audioBufferList = renderBuffer.mutableAudioBufferList
        audioBufferList.pointee.mBuffers.mDataByteSize = framesPerBuffer * bytesPerFrame
        guard lock.withLock({ wantsRunning && !pendingFlush }) else { return nil }
        renderLock.lock()
        let (rendered, contentFrames) = render(framesPerBuffer, audioBufferList)
        renderLock.unlock()
        if rendered < framesPerBuffer, let data = audioBufferList.pointee.mBuffers.mData {
            // keep the timeline contiguous: pad with silence
            let offset = Int(rendered * bytesPerFrame)
            memset(data + offset, 0, Int((framesPerBuffer - rendered) * bytesPerFrame))
        }
        audioBufferList.pointee.mBuffers.mDataByteSize = framesPerBuffer * bytesPerFrame

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: nextFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(framesPerBuffer),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            Logger.audioRendering.error("renderer output: CMSampleBufferCreate failed (\(status))")
            return nil
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        )
        guard status == noErr else {
            Logger.audioRendering.error("renderer output: setting sample data failed (\(status))")
            return nil
        }
        let startSeconds = Double(nextFrame) / Double(sampleRate)
        nextFrame += Int64(framesPerBuffer)
        let endSeconds = Double(nextFrame) / Double(sampleRate)
        lock.withLock {
            enqueuedEndSeconds = endSeconds
            contentTimeline.append((startSeconds, endSeconds, Int64(contentFrames)))
        }
        return (sampleBuffer, contentFrames)
    }

    private func pruneHistory() {
        let current = synchronizer.currentTime()
        guard current.isValid else { return }
        let currentSeconds = current.seconds
        lock.withLock {
            let heard = contentTimeline.prefix(while: { $0.end <= currentSeconds }).count
            contentTimeline.removeFirst(heard)
        }
        while let first = history.first {
            let end = CMSampleBufferGetPresentationTimeStamp(first) + CMSampleBufferGetDuration(first)
            guard end < current else { break }
            history.removeFirst()
        }
    }

    // MARK: Renderer notifications

    private func observeRenderer() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] notification in
            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self?.queue.async { self?.reenqueueAfterAutomaticFlush(at: flushTime) }
        })
        observers.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: nil
        ) { _ in
            Logger.audioRendering.info("renderer output: output configuration changed")
        })
        observers.append(center.addObserver(
            forName: AVSampleBufferRenderSynchronizer.rateDidChangeNotification,
            object: synchronizer,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.handleRateChange() }
        })
    }

    /// The renderer dropped its enqueued audio (e.g. the output route changed). The engine already
    /// consumed that audio, so enqueue it again from the history.
    private func reenqueueAfterAutomaticFlush(at flushTime: CMTime?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let time = flushTime ?? synchronizer.currentTime()
        var count = 0
        for sampleBuffer in history {
            let end = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) + CMSampleBufferGetDuration(sampleBuffer)
            guard end > time else { continue }
            renderer.enqueue(sampleBuffer)
            count += 1
        }
        Logger.audioRendering.info(
            "renderer output: flushed automatically at \(time.seconds, format: .fixed(precision: 2)) s, re-enqueued \(count) buffers"
        )
    }

    private func handleRateChange() {
        dispatchPrecondition(condition: .onQueue(queue))
        let rate = synchronizer.rate
        Logger.audioRendering.info("renderer output: synchronizer rate changed to \(rate)")
        // The system can stop the clock on its own (e.g. when the route changes back to the Mac).
        // Restart it if playback is wanted and nothing on our side paused it.
        if rate == 0, isRateRunning, clockStarted, lock.withLock({ wantsRunning || pendingDrainStop }) {
            // at most once per second, so a clock the system keeps stopping cannot loop
            let now = Date()
            guard now.timeIntervalSince(lastClockRestart) > 1 else { return }
            lastClockRestart = now
            Logger.audioRendering.info("renderer output: restarting stopped clock")
            synchronizer.rate = 1
        }
    }
}

/// Delivers delegate callbacks on the main queue after a delay, strictly in the order they were
/// scheduled (a later callback never overtakes an earlier one).
///
/// Used with `SampleBufferRendererOutput` so item changes are reported when they are heard,
/// not when they are rendered.
final class OrderedDelayedNotifier {
    private let lock = NSLock()
    private var pending = [(deadline: DispatchTime, block: () -> Void)]()
    private var lastDeadline = DispatchTime.now()

    func notify(after seconds: Double, _ block: @escaping () -> Void) {
        let deadline: DispatchTime = lock.withLock {
            var deadline = DispatchTime.now() + max(0, seconds)
            if deadline < lastDeadline {
                deadline = lastDeadline
            }
            lastDeadline = deadline
            pending.append((deadline, block))
            return deadline
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.deliver(upTo: .now())
        }
    }

    /// Delivers everything still pending right away (keeping the order), e.g. on seek or item change.
    func deliverAllPending() {
        DispatchQueue.main.async { [weak self] in
            self?.deliver(upTo: .distantFuture)
        }
        lock.withLock { lastDeadline = .now() }
    }

    private func deliver(upTo time: DispatchTime) {
        dispatchPrecondition(condition: .onQueue(.main))
        let due: [() -> Void] = lock.withLock {
            let count = pending.prefix(while: { $0.deadline <= time }).count
            let due = pending.prefix(count).map(\.block)
            pending.removeFirst(count)
            return due
        }
        due.forEach { $0() }
    }
}
