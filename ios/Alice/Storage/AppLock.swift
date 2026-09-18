import Foundation
import Observation

/// Alice's two lock surfaces: the app-wide Face ID gate and the per-note locks.
/// Extracted from AppStore; owns its own UserDefaults keys so preference reads
/// and writes stay in one place.
@MainActor
@Observable
final class AppLock {
    private enum Keys {
        static let lockedNotes = "alice.notes.locked"
        static let requireUnlock = "alice.lock.required"
        static let lockGrace = "alice.lock.graceSeconds"
    }

    private let defaults: UserDefaults

    /// Face ID (or the passcode) before Alice shows anything.
    var requireUnlock = false {
        didSet {
            defaults.set(requireUnlock, forKey: Keys.requireUnlock)
            if !requireUnlock { appLocked = false }
        }
    }
    /// How long Alice may be away before it locks again, in seconds.
    var lockGrace = 60 {
        didSet { defaults.set(lockGrace, forKey: Keys.lockGrace) }
    }
    /// The app's content is covered until the owner unlocks it.
    var appLocked = false
    /// When Alice last left the foreground, for the grace period.
    var leftForegroundAt: Date?

    /// Notes that ask for Face ID before they open. Their words stay in the
    /// notes store, where agents still read them: this locks the phone's view.
    private(set) var lockedNotes: Set<String> = [] {
        didSet { defaults.set(Array(lockedNotes), forKey: Keys.lockedNotes) }
    }
    /// Locked notes were unlocked once; they stay open until Alice leaves the
    /// foreground, as in Notes.
    var lockedNotesOpen = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lockedNotes = Set(defaults.stringArray(forKey: Keys.lockedNotes) ?? [])
        requireUnlock = defaults.bool(forKey: Keys.requireUnlock)
        if defaults.object(forKey: Keys.lockGrace) != nil {
            lockGrace = defaults.integer(forKey: Keys.lockGrace)
        }
        appLocked = requireUnlock
    }

    func isLocked(_ note: Note) -> Bool { lockedNotes.contains(note.id) }

    func setLocked(_ note: Note, _ locked: Bool) {
        if locked { lockedNotes.insert(note.id) } else { lockedNotes.remove(note.id) }
    }

    /// Asks for Face ID when a locked note is to be opened, once per visit.
    func unlockNotes() async -> Bool {
        if lockedNotesOpen { return true }
        let ok = await Biometrics.authenticate(reason: "Unlock your locked notes.")
        if ok { lockedNotesOpen = true }
        return ok
    }
}
