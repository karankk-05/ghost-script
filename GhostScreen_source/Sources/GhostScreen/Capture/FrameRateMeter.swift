import Foundation
import QuartzCore

/// Frame accounting on the video queue with a 1 Hz stats snapshot. All
/// count* methods MUST be called on the meter's queue (the SCStream sample
/// handler queue); the timer runs there too, so no locking is needed.
final class FrameRateMeter: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    private var frames = 0
    private var dropped = 0
    private var idle = 0
    private var lastEventAt: CFTimeInterval = CACurrentMediaTime()

    /// Called on the video queue — consumers hop to the MainActor themselves.
    var onStats: (@Sendable (CaptureStats) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        queue.async { [self] in
            lastEventAt = CACurrentMediaTime()
            frames = 0; dropped = 0; idle = 0
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.emit() }
            timer?.cancel()
            timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    func countFrame() {
        frames += 1
        lastEventAt = CACurrentMediaTime()
    }

    func countDropped() {
        dropped += 1
        lastEventAt = CACurrentMediaTime()
    }

    func countIdle() {
        idle += 1
        lastEventAt = CACurrentMediaTime()
    }

    private func emit() {
        let stats = CaptureStats(fps: Double(frames),
                                 droppedFrames: dropped,
                                 idleFrames: idle,
                                 lastEventAge: CACurrentMediaTime() - lastEventAt)
        frames = 0; dropped = 0; idle = 0
        onStats?(stats)
    }
}
