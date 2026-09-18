import XCTest
@testable import Alice

@MainActor
final class AppLockTests: XCTestCase {
    private func lock() throws -> (AppLock, String) {
        let suite = "alice.lock-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppLock(defaults: defaults), suite)
    }

    private func note(_ id: String) -> Note {
        Note(id: id, createdAt: nil, text: "")
    }

    func testDefaultsRestoreOnANewInstance() throws {
        let (lock, suite) = try lock()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        lock.requireUnlock = true
        lock.lockGrace = 300
        lock.setLocked(note("n1"), true)
        lock.setLocked(note("n2"), true)
        lock.setLocked(note("n2"), false)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restored = AppLock(defaults: defaults)
        XCTAssertTrue(restored.requireUnlock)
        XCTAssertTrue(restored.appLocked)
        XCTAssertEqual(restored.lockGrace, 300)
        XCTAssertTrue(restored.isLocked(note("n1")))
        XCTAssertFalse(restored.isLocked(note("n2")))
    }

    func testDisablingUnlockClearsTheLock() throws {
        let (lock, suite) = try lock()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        lock.requireUnlock = true
        lock.appLocked = true
        lock.requireUnlock = false
        XCTAssertFalse(lock.appLocked)
    }

    func testFreshInstanceIsUnlockedWithoutPreference() throws {
        let (lock, suite) = try lock()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        XCTAssertFalse(lock.requireUnlock)
        XCTAssertFalse(lock.appLocked)
        XCTAssertEqual(lock.lockGrace, 60)
    }
}
