import Foundation

/// Small records kept as files in Application Support instead of `UserDefaults`.
///
/// The notes snapshot (attachments included) and Recently Deleted were rewritten whole into the
/// preferences plist on every edit: cfprefsd re-serialises the entire domain each time, megabytes
/// per autosave. A file per record costs only its own bytes. Protection is iOS' default
/// (until first unlock): a background relaunch with the phone locked can still read them.
enum PrivateFiles {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Private", directoryHint: .isDirectory)
    }

    private static func url(_ key: String) -> URL? {
        directory?.appending(path: key + ".json", directoryHint: .notDirectory)
    }

    static func read(_ key: String) -> Data? {
        guard let url = url(key) else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    static func write(_ data: Data, _ key: String) -> Bool {
        guard let directory, let url = url(key) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            DiagnosticsLog.write("privateFiles.writeFailed \(key)")
            return false
        }
    }

    static func remove(_ key: String) {
        guard let url = url(key) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
