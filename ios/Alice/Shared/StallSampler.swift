import Darwin
import Foundation

#if DEBUG
/// Finds out what the main thread is doing when it stops answering.
///
/// Off unless the app is launched with `ALICE_STALL_SAMPLER=1`, which only a
/// developer tool does. A watcher thread pings the main thread; once a ping
/// goes unanswered for a quarter of a second, it interrupts the main thread
/// every 40 ms and records where it is. When the main thread is free again it
/// prints the stall's length and the functions it was in most often, prefixed
/// `[stall]`, to the console a debugger or `devicectl --console` shows.
///
/// Built for diagnosis on a device with no profiler available; nothing of it
/// ships outside debug builds.
enum StallSampler {
    private static let maxFrames = 96
    private static let maxSamples = 80

    // Written by the signal handler, which runs on the main thread, and read
    // by the main thread after the stall. Nothing else touches them.
    nonisolated(unsafe) private static let frames =
        UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames * maxSamples)
    nonisolated(unsafe) private static let depths = UnsafeMutablePointer<Int32>.allocate(capacity: maxSamples)
    nonisolated(unsafe) private static var taken: Int = 0
    nonisolated(unsafe) private static var main: pthread_t?

    private final class Heartbeat: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var last = CFAbsoluteTimeGetCurrent()
        func beat() {
            os_unfair_lock_lock(&lock); last = CFAbsoluteTimeGetCurrent(); os_unfair_lock_unlock(&lock)
        }
        var silence: Double {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return CFAbsoluteTimeGetCurrent() - last
        }
    }

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["ALICE_STALL_SAMPLER"] == "1",
              Thread.isMainThread, main == nil
        else { return }
        main = pthread_self()
        signal(SIGUSR2) { _ in
            let n = StallSampler.taken
            guard n < StallSampler.maxSamples else { return }
            StallSampler.depths[n] = backtrace(
                StallSampler.frames + n * StallSampler.maxFrames, Int32(StallSampler.maxFrames)
            )
            StallSampler.taken = n + 1
        }
        let heartbeat = Heartbeat()
        let watcher = Thread {
            var stalledSince: Double?
            while true {
                DispatchQueue.main.async { heartbeat.beat() }
                usleep(40_000)
                let silence = heartbeat.silence
                if silence > 0.25, let thread = main {
                    if stalledSince == nil { stalledSince = CFAbsoluteTimeGetCurrent() - silence }
                    pthread_kill(thread, SIGUSR2)
                } else if let start = stalledSince {
                    stalledSince = nil
                    let length = CFAbsoluteTimeGetCurrent() - start
                    DispatchQueue.main.async { report(length) }
                }
            }
        }
        watcher.name = "alice.stall-sampler"
        watcher.qualityOfService = .userInteractive
        watcher.start()
        print("[stall] sampler on")
    }

    private static func report(_ length: Double) {
        let count = taken
        defer { taken = 0 }
        guard count > 0 else { return }
        var inclusive: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        var first: [String] = []
        for sample in 0..<count {
            let depth = Int(depths[sample])
            var seen = Set<String>()
            // Frames 0–1 are the signal handler and its trampoline.
            for index in 2..<max(2, depth) {
                let name = symbol(frames[sample * maxFrames + index])
                if index == 2 { leaves[name, default: 0] += 1 }
                if sample == 0 { first.append(name) }
                if seen.insert(name).inserted { inclusive[name, default: 0] += 1 }
            }
        }
        print("[stall] \(Int(length * 1000)) ms, \(count) samples")
        for (name, hits) in inclusive.sorted(by: { $0.value > $1.value }).prefix(45) {
            print("[stall] incl \(hits)/\(count) \(name)")
        }
        for (name, hits) in leaves.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("[stall] leaf \(hits)/\(count) \(name)")
        }
        for (index, name) in first.prefix(70).enumerated() {
            print("[stall] first \(index) \(name)")
        }
    }

    private static func symbol(_ address: UnsafeMutableRawPointer?) -> String {
        guard let address else { return "?" }
        var info = Dl_info()
        guard dladdr(address, &info) != 0 else { return "?" }
        let image = info.dli_fname.map { String(cString: $0) }
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image)`\(name)"
    }
}
#endif
