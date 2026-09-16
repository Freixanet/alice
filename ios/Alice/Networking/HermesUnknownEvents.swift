import Foundation
import OSLog

/// Stream events Alice does not know, kept rather than dropped.
///
/// Hermes adds event kinds between releases. An unknown one must not break a
/// reply, but throwing it away made every such addition invisible: a run that
/// ended with a new terminal event looked like a bot that finished with
/// nothing to say. Each unknown kind is counted here, with the keys it
/// carried, so the System screen can show what this Hermes is sending that
/// Alice has not learnt yet — and a contributor knows exactly what to add.
final class HermesUnknownEvents: @unchecked Sendable {
    struct Sighting: Equatable, Sendable {
        let type: String
        var count: Int
        var lastSeen: Date
        /// The payload's top-level keys, sorted: what the event carried, never
        /// its contents, which may hold a person's words.
        var keys: [String]
    }

    static let shared = HermesUnknownEvents()

    /// Where the event came from, so a kind seen on one transport is not
    /// confused with the same name on another.
    enum Transport: String, Sendable { case runStream, botSocket, liveEvents }

    private let lock = NSLock()
    private var sightings: [String: Sighting] = [:]
    private let log = Logger(subsystem: "com.freixanet.alice", category: "hermes-events")

    /// How many kinds are remembered before the oldest is let go.
    static let capacity = 64

    func record(_ type: String, transport: Transport, payload: [String: Any], now: Date = Date()) {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let key = "\(transport.rawValue):\(trimmed)"
        let keys = payload.keys.sorted()
        let isNew: Bool = lock.withLock {
            if var known = sightings[key] {
                known.count += 1
                known.lastSeen = now
                known.keys = keys
                sightings[key] = known
                return false
            }
            if sightings.count >= Self.capacity,
               let oldest = sightings.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                sightings.removeValue(forKey: oldest.key)
            }
            sightings[key] = Sighting(type: trimmed, count: 1, lastSeen: now, keys: keys)
            return true
        }
        if isNew {
            log.notice("Unknown Hermes event \(trimmed, privacy: .public) on \(transport.rawValue, privacy: .public) with keys \(keys.joined(separator: ","), privacy: .public)")
        }
    }

    /// Everything seen, most recent first.
    var all: [Sighting] {
        lock.withLock { sightings.values.sorted { $0.lastSeen > $1.lastSeen } }
    }

    var isEmpty: Bool { lock.withLock { sightings.isEmpty } }

    func reset() { lock.withLock { sightings.removeAll() } }
}
