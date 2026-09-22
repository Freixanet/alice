import Foundation
import QuartzCore
import UIKit

/// How smoothly the app is running, measured while developer mode is on.
///
/// Two readings, both cheap: stalls — the main thread not answering for more
/// than a quarter of a second, which is what "the app froze" is — and frames,
/// for the live meter. The freezes the person hit in Agents were only found
/// with a debugger and a sampler; this says, from the app itself, whether
/// one has happened this session and how long it lasted.
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
            let watcher = Watcher { [weak self] seconds in
                Task { @MainActor in self?.record(seconds) }
            }
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

    private func record(_ seconds: Double) {
        stalls.insert(Stall(at: Date(), seconds: seconds), at: 0)
        if stalls.count > 50 { stalls.removeLast(stalls.count - 50) }
        DiagnosticsLog.write("stall \(Int(seconds * 1000))ms")
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
    /// answer takes. Nothing of the main thread's work is sampled here —
    /// `StallSampler` does that, on demand, in debug builds.
    private final class Watcher: @unchecked Sendable {
        private let report: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var lastAnswer = CACurrentMediaTime()
        private var stopped = false
        private var thread: Thread?

        init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

        func start() {
            let thread = Thread { [weak self] in self?.loop() }
            thread.name = "alice.hitch-monitor"
            thread.qualityOfService = .utility
            self.thread = thread
            thread.start()
        }

        func stop() { lock.withLock { stopped = true } }

        private func loop() {
            var stalledSince: CFTimeInterval?
            while !lock.withLock({ stopped }) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock { self.lastAnswer = CACurrentMediaTime() }
                }
                usleep(100_000)
                let silence = CACurrentMediaTime() - lock.withLock { lastAnswer }
                if silence > 0.25 {
                    if stalledSince == nil { stalledSince = CACurrentMediaTime() - silence }
                } else if let since = stalledSince {
                    stalledSince = nil
                    report(CACurrentMediaTime() - since)
                }
            }
        }
    }
}
