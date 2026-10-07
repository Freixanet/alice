import Foundation

/// A bounded read with a reason for rejection, shared by the picker's UI and loader.
enum AttachmentFileReader {
    static let maxBytes = 20 * 1024 * 1024

    enum Failure: LocalizedError {
        case tooLarge, unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                String(localized: "This file is too large. Choose a file of 20 MB or less.")
            case .unreadable:
                String(localized: "This attachment could not be read. Try downloading it first or choosing it again.")
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes { throw Failure.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() }
        catch { throw Failure.unreadable }
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        return data
    }
}
