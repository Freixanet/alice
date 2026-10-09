import Foundation

/// Host-only regression check: no phone, picker, personal files or Hermes.
@main struct CheckAttachmentFileReader {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture.bin")
        try Data("draft attachment".utf8).write(to: file)
        let content = try AttachmentFileReader.read(file)
        precondition(content == Data("draft attachment".utf8))
        try Data().write(to: file)
        let empty = try AttachmentFileReader.read(file)
        precondition(empty.isEmpty)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AttachmentFileReader.maxBytes))
        let boundary = try AttachmentFileReader.read(file)
        precondition(boundary.count == AttachmentFileReader.maxBytes)
        try handle.truncate(atOffset: UInt64(AttachmentFileReader.maxBytes + 1))
        do {
            _ = try AttachmentFileReader.read(file)
            preconditionFailure("Oversized file was accepted")
        } catch AttachmentFileReader.Failure.tooLarge {
            precondition(AttachmentFileReader.Failure.tooLarge.errorDescription?.isEmpty == false)
        }
        try handle.close()
        try FileManager.default.removeItem(at: file)
        do {
            _ = try AttachmentFileReader.read(file)
            preconditionFailure("Missing file was accepted")
        } catch AttachmentFileReader.Failure.unreadable {}
        print("PASS: content, empty file, exact limit, oversize reason and unreadable reason")
    }
}
