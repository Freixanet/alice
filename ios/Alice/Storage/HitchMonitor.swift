import Foundation
import QuartzCore
import UIKit

/// How smoothly the app is running, measured while developer mode is on.
///
/// Two readings, both cheap: stalls — the main thread not answering for more
/// than a quarter of a second, which is what "the app froze" is — and frames,
/// for the live meter. Each stall is written to the diagnostics log with the
/// functions the main thread was in, so a later look can tell a real hitch
/// from the app having been suspended.
@MainActor
@Observable
final class HitchMonitor {
    static let shared = HitchMonitor()

    struct Stall: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let seconds: Double
    }

    /// This session's stalls, newest first, at most fifty.
    private(set) var stalls: [Stall] = []
    /// Frames drawn in the last second, and how many of them came late.
    private(set) var framesPerSecond = 0
    private(set) var lateFrames = 0

    private(set) var running = false
    private var watcher: Watcher?
    private var link: CADisplayLink?
    private var frameCount = 0
    private var lateCount = 0
    private var windowStart: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0

    var worst: Double { stalls.map(\.seconds).max() ?? 0 }

    func setRunning(_ on: Bool) {
        guard on != running else { return }
        running = on
        if on {
            #if DEBUG
            StallSampler.arm()
            #endif
            let watcher = Watcher { [weak self] seconds, trace in
                Task { @MainActor in self?.record(seconds, trace: trace) }
            }
            watcher.followAppState()
            watcher.start()
            self.watcher = watcher
            let link = CADisplayLink(target: FrameTarget(self), selector: #selector(FrameTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            watcher?.stop()
            watcher = nil
            link?.invalidate()
            link = nil
            framesPerSecond = 0
            lateFrames = 0
        }
    }

    func reset() { stalls = [] }

    private func record(_ seconds: Double, trace: [String]) {
        stalls.insert(Stall(at: Date(), seconds: seconds), at: 0)
        if stalls.count > 50 { stalls.removeLast(stalls.count - 50) }
        DiagnosticsLog.write("stall \(Int(seconds * 1000))ms")
        for line in trace {
            DiagnosticsLog.write(line)
        }
    }

    fileprivate func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if windowStart == 0 { windowStart = now; lastFrame = now; return }
        let expected = link.targetTimestamp - link.timestamp
        if now - lastFrame > max(expected, 1.0 / 120) * 1.5 { lateCount += 1 }
        lastFrame = now
        frameCount += 1
        if now - windowStart >= 1 {
            if framesPerSecond != frameCount { framesPerSecond = frameCount }
            if lateFrames != lateCount { lateFrames = lateCount }
            frameCount = 0
            lateCount = 0
            windowStart = now
        }
    }

    /// A display link holds its target strongly; this keeps it from holding
    /// the monitor. Added to the main run loop, so ticks arrive on the main thread.
    @MainActor
    private final class FrameTarget: NSObject {
        weak var monitor: HitchMonitor?
        init(_ monitor: HitchMonitor) { self.monitor = monitor }
        @objc func tick(_ link: CADisplayLink) {
            monitor?.frame(link)
        }
    }

    /// Pings the main thread from its own thread and times how long an
    /// answer takes. While the answer is late, a debug build samples where
    /// that thread is (`StallSampler`) so the log can name the functions.
    private final class Watcher: @unchecked Sendable {
        private let report: @Sendable (Double, [String]) -> Void
        private let lock = NSLock()
        private var lastAnswer = CACurrentMediaTime()
        private var stopped = false
        /// Off while the app is not in front: a suspended app answers nothing,
        /// and counting that as a freeze reported a phone left locked for
        /// seventeen minutes as a 1,047-second stall.
        private var foreground = true
        private var thread: Thread?
        private var observers: [NSObjectProtocol] = []

        init(report: @escaping @Sendable (Double, [String]) -> Void) { self.report = report }

        func start() {
            let thread = Thread { [weak self] in self?.loop() }
            thread.name = "alice.hitch-monitor"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
        }

        func stop() {
            lock.withLock { stopped = true }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        /// Follows the app in and out of the foreground. Called on the main thread.
        func followAppState() {
            let center = NotificationCenter.default
            let set: @Sendable (Bool) -> Void = { [weak self] on in
                guard let self else { return }
                self.lock.withLock {
                    self.foreground = on
                    // Coming back, the silence so far was the suspension.
                    self.lastAnswer = CACurrentMediaTime()
                }
            }
            observers = [
                center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in set(true) },
                center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in set(false) },
            ]
        }

        private func loop() {
            var stalledSince: CFTimeInterval?
            while !lock.withLock({ stopped }) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self.lastAnswer = CACurrentMediaTime() }
                }
                let slept = CACurrentMediaTime()
                usleep(100_000)
                let now = CACurrentMediaTime()
                // This thread itself was held far past its nap: the whole
                // process was suspended, not the main thread busy. Nothing
                // measured across that gap is a freeze.
                let suspended = now - slept > 1
                let (silence, inFront) = lock.withLock { (now - lastAnswer, foreground) }
                if suspended || !inFront {
                    if stalledSince != nil {
                        stalledSince = nil
                        #if DEBUG
                        _ = DispatchQueue.main.sync { StallSampler.consume() }
                        #endif
                    }
                    if suspended { lock.withLock { lastAnswer = now } }
                    continue
                }
                if silence > 0.25 {
                    if stalledSince == nil { stalledSince = CACurrentMediaTime() - silence }
                    #if DEBUG
                    StallSampler.capture()
                    #endif
                } else if let since = stalledSince {
                    stalledSince = nil
                    let seconds = CACurrentMediaTime() - since
                    // The last sample's handler runs on the main thread.
                    // Reading the buffer there waits until that handler is done.
                    let trace = DispatchQueue.main.sync {
                        #if DEBUG
                        StallSampler.consume()
                        #else
                        [String]()
                        #endif
                    }
                    report(seconds, trace)
                }
            }
        }
    }
}
