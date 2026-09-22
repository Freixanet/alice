import Darwin
import Foundation

#if DEBUG
/// Where the main thread is while it is not answering.
///
/// Armed while the hitch monitor runs (developer mode). A watcher thread
/// interrupts the main thread during a stall and, once the stall ends, the
/// functions it was in are written to the diagnostics log. Nothing of this
/// is in a release build.
enum StallSampler {
    private static let maxFrames = 64
    private static let maxSamples = 40

    // Written by the signal handler on the main thread, read after the stall
    // on the main thread. Nothing else touches them.
    nonisolated(unsafe) private static let frames =
        UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxFrames * maxSamples)
    nonisolated(unsafe) private static let depths = UnsafeMutablePointer<Int32>.allocate(capacity: maxSamples)
    nonisolated(unsafe) private static var taken: Int = 0
    nonisolated(unsafe) private static var main: pthread_t?
    nonisolated(unsafe) private static var armed = false

    /// Installs the handler. Call on the main thread, once the monitor is on.
    static func arm() {
        guard Thread.isMainThread, !armed else { return }
        armed = true
        main = pthread_self()
        signal(SIGUSR2) { _ in
            let n = StallSampler.taken
            guard n < StallSampler.maxSamples else { return }
            StallSampler.depths[n] = backtrace(
                StallSampler.frames + n * StallSampler.maxFrames, Int32(StallSampler.maxFrames)
            )
            StallSampler.taken = n + 1
        }
    }

    /// One sample of the main thread, from the watcher. Ignored until `arm`.
    static func capture() {
        guard let main else { return }
        pthread_kill(main, SIGUSR2)
    }

    /// The functions seen most often during the stall that just ended, then
    /// clears the buffer. Call on the main thread, after capturing has stopped.
    static func consume() -> [String] {
        let count = taken
        taken = 0
        guard count > 0 else { return [] }
        var inclusive: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        for sample in 0..<count {
            let depth = Int(depths[sample])
            var seen = Set<String>()
            // Frames 0–1 are the signal handler and its trampoline.
            for index in 2..<max(2, depth) {
                let name = symbol(frames[sample * maxFrames + index])
                if name.contains("StallSampler") || name.contains("_sigtramp") { continue }
                if index == 2 { leaves[name, default: 0] += 1 }
                if seen.insert(name).inserted { inclusive[name, default: 0] += 1 }
            }
        }
        var lines: [String] = []
        for (name, hits) in inclusive.sorted(by: { $0.value > $1.value }).prefix(8) {
            lines.append("stall.in \(hits)/\(count) \(name)")
        }
        if let (name, hits) = leaves.max(by: { $0.value < $1.value }) {
            lines.append("stall.at \(hits)/\(count) \(name)")
        }
        return lines
    }

    private static func symbol(_ address: UnsafeMutableRawPointer?) -> String {
        guard let address else { return "?" }
        var info = Dl_info()
        guard dladdr(address, &info) != 0 else { return "?" }
        let image = info.dli_fname.map { String(cString: $0) }
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        let raw = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image)`\(demangle(raw))"
    }

    private static func demangle(_ raw: String) -> String {
        guard raw.hasPrefix("$s") || raw.hasPrefix("_T") else { return raw }
        return raw.withCString { pointer in
            guard let out = swift_demangle(pointer, strlen(pointer), nil, nil, 0) else { return raw }
            defer { free(out) }
            let text = String(cString: out)
            guard let paren = text.firstIndex(of: "(") else { return text }
            return String(text[..<paren])
        }
    }
}

@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangled: UnsafePointer<CChar>?,
    _ length: Int,
    _ output: UnsafeMutablePointer<CChar>?,
    _ outputLength: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
#endif
