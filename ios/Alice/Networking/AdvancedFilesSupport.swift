import Foundation

struct HermesFSDirectoryEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
}

struct HermesFSDirectoryListing: Hashable, Sendable {
    var entries: [HermesFSDirectoryEntry]
    var error: String?
}

struct HermesFSTextSnapshot: Hashable, Sendable {
    var path: String
    var text: String
    var binary: Bool
    var byteSize: Int64
    var language: String
    var mimeType: String
    var truncated: Bool
}

struct HermesFSDefaultLocation: Hashable, Sendable {
    var cwd: String
    var branch: String
}

struct HermesFSWriteResult: Hashable, Sendable {
    var path: String
    var byteSize: Int64
}

struct HermesFSBinaryPreview: Hashable, Sendable {
    var data: Data
    var mimeType: String
}

struct HermesDownloadedFile: Hashable, Sendable {
    var url: URL
    var name: String
    var mimeType: String
    var size: Int64
}

extension DashboardClient {
    func filesystemDirectory(path: String) async throws -> HermesFSDirectoryListing {
        try Self.filesystemDirectory(
            from: await get("api/fs/list?path=\(Self.advancedFileQuery(path))")
        )
    }

    func filesystemText(path: String) async throws -> HermesFSTextSnapshot {
        try Self.filesystemText(
            from: await get("api/fs/read-text?path=\(Self.advancedFileQuery(path))")
        )
    }

    func writeFilesystemText(path: String, content: String) async throws -> HermesFSWriteResult {
        let object = try await send("POST", "api/fs/write-text", ["path": path, "content": content])
        guard object["ok"] as? Bool == true,
              let outputPath = Self.advancedString(object["path"]),
              let bytes = Self.advancedInt64(object["byteSize"]) else {
            throw Failure.unreadable
        }
        return .init(path: outputPath, byteSize: bytes)
    }

    func filesystemData(path: String) async throws -> HermesFSBinaryPreview {
        let object = try await get("api/fs/read-data-url?path=\(Self.advancedFileQuery(path))")
        guard let dataURL = object["dataUrl"] as? String else { throw Failure.unreadable }
        return try Self.binaryPreview(fromDataURL: dataURL)
    }

    func filesystemGitRoot(path: String) async throws -> String? {
        let object = try await get("api/fs/git-root?path=\(Self.advancedFileQuery(path))")
        if object["root"] is NSNull || object["root"] == nil { return nil }
        guard let root = object["root"] as? String else { throw Failure.unreadable }
        return root.isEmpty ? nil : root
    }

    func filesystemDefaultLocation() async throws -> HermesFSDefaultLocation {
        let object = try await get("api/fs/default-cwd")
        guard let cwd = Self.advancedString(object["cwd"]),
              let branch = object["branch"] as? String else { throw Failure.unreadable }
        return .init(cwd: cwd, branch: branch)
    }

    func downloadManagedFile(path: String) async throws -> HermesDownloadedFile {
        let route = "api/files/download?path=\(Self.advancedFileQuery(path))"
        let (temporary, response) = try await rawDownload(route)
        return try Self.persistDownloadedFile(
            temporary, response: response, suggestedName: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    func downloadFilesystemFile(path: String) async throws -> HermesDownloadedFile {
        let route = "api/fs/download?path=\(Self.advancedFileQuery(path))"
        let (temporary, response) = try await rawDownload(route)
        return try Self.persistDownloadedFile(
            temporary, response: response, suggestedName: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    /// Multipart upload backed by a temporary file. The source and request body
    /// are copied in 1 MiB chunks; Alice never materializes a large upload as a
    /// Data value or base64 string.
    @discardableResult
    func uploadManagedFileStream(
        path: String, fileURL: URL, mimeType: String = "application/octet-stream",
        overwrite: Bool = true
    ) async throws -> ManagedRemoteFile {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let maxBytes: Int64 = 100 * 1024 * 1024
        guard bytes <= maxBytes else {
            throw Failure.http(413, detail: "File is too large; Hermes caps managed files at 100 MB")
        }

        let boundary = "AliceBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let bodyURL = try Self.buildMultipartBody(
            source: fileURL, path: path, mimeType: mimeType,
            overwrite: overwrite, boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let (data, _) = try await rawUpload(
            "POST", "api/files/upload-stream", bodyFile: bodyURL,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = object["entry"] as? [String: Any],
              let entry = Self.managedFileEntry(from: row) else { throw Failure.unreadable }
        return entry
    }

    static func filesystemDirectory(from object: [String: Any]) throws -> HermesFSDirectoryListing {
        guard let rows = object["entries"] as? [[String: Any]] else { throw Failure.unreadable }
        let entries = try rows.map { row -> HermesFSDirectoryEntry in
            guard let name = advancedString(row["name"]),
                  let path = advancedString(row["path"]),
                  let directory = row["isDirectory"] as? Bool else { throw Failure.unreadable }
            return .init(name: name, path: path, isDirectory: directory)
        }
        let error: String?
        if object["error"] is NSNull || object["error"] == nil {
            error = nil
        } else if let value = object["error"] as? String {
            error = value
        } else {
            throw Failure.unreadable
        }
        return .init(entries: entries, error: error)
    }

    static func filesystemText(from object: [String: Any]) throws -> HermesFSTextSnapshot {
        guard let path = advancedString(object["path"]),
              let text = object["text"] as? String,
              let binary = object["binary"] as? Bool,
              let bytes = advancedInt64(object["byteSize"]),
              let language = object["language"] as? String,
              let mime = object["mimeType"] as? String,
              let truncated = object["truncated"] as? Bool else { throw Failure.unreadable }
        return .init(
            path: path, text: text, binary: binary, byteSize: bytes,
            language: language, mimeType: mime, truncated: truncated
        )
    }

    static func binaryPreview(fromDataURL dataURL: String) throws -> HermesFSBinaryPreview {
        guard dataURL.lowercased().hasPrefix("data:"),
              let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].lowercased().contains(";base64") else { throw Failure.unreadable }
        let header = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let mime = header.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "application/octet-stream"
        guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else {
            throw Failure.unreadable
        }
        return .init(data: data, mimeType: mime.isEmpty ? "application/octet-stream" : mime)
    }

    static func advancedParentPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        let parent = url.deletingLastPathComponent().path
        return parent == trimmed ? nil : (parent.isEmpty ? "/" : parent)
    }

    static func advancedFileQuery(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func normalizedFileName(_ raw: String) -> String {
        let base = URL(fileURLWithPath: raw).lastPathComponent
        let stripped = base
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
        return stripped.isEmpty ? "file" : stripped
    }

    private static func advancedString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func advancedInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private static func persistDownloadedFile(
        _ temporaryURL: URL, response: HTTPURLResponse, suggestedName: String
    ) throws -> HermesDownloadedFile {
        let name = normalizedFileName(suggestedName)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "alice-remote-downloads", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: name)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mime = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first.map(String.init)
            ?? "application/octet-stream"
        return .init(url: destination, name: name, mimeType: mime, size: bytes)
    }

    static func buildMultipartBody(
        source: URL, path: String, mimeType: String, overwrite: Bool, boundary: String
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "alice-multipart", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outputURL = folder.appending(path: UUID().uuidString + ".body")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw Failure.unreachable
        }

        let output = try FileHandle(forWritingTo: outputURL)
        let input = try FileHandle(forReadingFrom: source)
        var success = false
        defer {
            try? input.close()
            try? output.close()
            if !success { try? FileManager.default.removeItem(at: outputURL) }
        }

        func write(_ string: String) throws {
            try output.write(contentsOf: Data(string.utf8))
        }

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"path\"\r\n\r\n")
        try write(path)
        try write("\r\n--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n")
        try write(overwrite ? "true" : "false")
        try write("\r\n--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(normalizedFileName(source.lastPathComponent))\"\r\n")
        try write("Content-Type: \(mimeType)\r\n\r\n")

        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        success = true
        return outputURL
    }
}
