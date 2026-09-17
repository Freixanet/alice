import Foundation

/// A plain-text trace of how replies travel, kept in the app's Documents so it
/// can be copied off the phone (`devicectl … --domain-type appDataContainer`)
/// when a reply goes missing. Never message text: ids, states and errors only.
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "com.freixanet.alice.diagnostics")
    private static let limit = 1_500_000

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("diagnostics.log")
    }

    static func write(_ message: @autoclosure () -> String) {
        let line = "\(Date().ISO8601Format(.iso8601(timeZone: .current))) \(message())\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > limit {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
