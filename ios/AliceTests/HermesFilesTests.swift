import XCTest
@testable import Alice

final class HermesFilesTests: XCTestCase {
    func testListingPreservesHermesNavigationAndMetadata() throws {
        let listing = try DashboardClient.managedFilesListing(from: [
            "root": "/srv/hermes",
            "path": "/srv/hermes/work",
            "parent": "/srv/hermes",
            "locked_root": "/srv/hermes",
            "can_change_path": false,
            "entries": [[
                "name": "notes.md",
                "path": "/srv/hermes/work/notes.md",
                "is_directory": false,
                "size": 42,
                "mtime": 1_700_000_000.0,
                "mime_type": "text/markdown",
            ]],
        ])

        XCTAssertEqual(listing.path, "/srv/hermes/work")
        XCTAssertEqual(listing.parent, "/srv/hermes")
        XCTAssertEqual(listing.lockedRoot, "/srv/hermes")
        XCTAssertFalse(listing.canChangePath)
        XCTAssertEqual(listing.entries.first?.name, "notes.md")
        XCTAssertEqual(listing.entries.first?.size, 42)
        XCTAssertEqual(listing.entries.first?.mimeType, "text/markdown")
    }

    func testMalformedListingIsNotSilentlyTreatedAsEmpty() {
        XCTAssertThrowsError(try DashboardClient.managedFilesListing(from: ["path": "/tmp"]))
        XCTAssertThrowsError(try DashboardClient.managedFilesListing(from: [
            "path": "/tmp",
            "entries": [["name": "broken"]],
        ]))
    }

    func testManagedFileDataURLDecodesExactly() throws {
        let bytes = Data("hello hermes".utf8)
        let file = try DashboardClient.managedFileContents(from: [
            "name": "hello.txt",
            "path": "/tmp/hello.txt",
            "size": bytes.count,
            "mime_type": "text/plain",
            "data_url": "data:text/plain;base64,\(bytes.base64EncodedString())",
        ])
        XCTAssertEqual(file.data, bytes)
        XCTAssertEqual(file.size, bytes.count)
    }

    func testRemotePathJoinKeepsRootSemantics() {
        XCTAssertTrue(RemoteFilePath.isSafeComponent("notes.md"))
        XCTAssertFalse(RemoteFilePath.isSafeComponent(".."))
        XCTAssertFalse(RemoteFilePath.isSafeComponent("folder/name"))
        XCTAssertEqual(RemoteFilePath.join("/", "notes.md"), "/notes.md")
        XCTAssertEqual(RemoteFilePath.join("/srv/hermes", "/notes.md/"), "/srv/hermes/notes.md")
        XCTAssertEqual(RemoteFilePath.join("relative", "child"), "relative/child")
    }

    func testFilesystemDirectoryPreservesServerErrorInsteadOfFakeEmptySuccess() throws {
        let listing = try DashboardClient.filesystemDirectory(from: [
            "entries": [["name": "src", "path": "/repo/src", "isDirectory": true]],
            "error": "EACCES",
        ])
        XCTAssertEqual(listing.entries.count, 1)
        XCTAssertEqual(listing.entries[0].path, "/repo/src")
        XCTAssertEqual(listing.error, "EACCES")
    }

    func testMalformedFilesystemDirectoryDoesNotBecomeEmptyDirectory() {
        XCTAssertThrowsError(try DashboardClient.filesystemDirectory(from: [:]))
        XCTAssertThrowsError(try DashboardClient.filesystemDirectory(from: [
            "entries": [["name": "broken", "path": "/tmp/broken"]],
        ]))
    }

    func testFilesystemTextPreservesPreviewSafetyMetadata() throws {
        let snapshot = try DashboardClient.filesystemText(from: [
            "binary": false,
            "byteSize": 700_000,
            "language": "swift",
            "mimeType": "text/x-swift",
            "path": "/repo/App.swift",
            "text": "struct App {}",
            "truncated": true,
        ])
        XCTAssertEqual(snapshot.path, "/repo/App.swift")
        XCTAssertEqual(snapshot.byteSize, 700_000)
        XCTAssertEqual(snapshot.language, "swift")
        XCTAssertTrue(snapshot.truncated)
        XCTAssertFalse(snapshot.binary)
    }

    func testMalformedFilesystemTextIsNotEditableState() {
        XCTAssertThrowsError(try DashboardClient.filesystemText(from: [
            "path": "/tmp/a.txt", "text": "hello",
        ]))
    }

    func testFilesystemDataURLPreservesBytesAndMimeType() throws {
        let bytes = Data([0, 1, 2, 3, 255])
        let preview = try DashboardClient.binaryPreview(
            fromDataURL: "data:application/octet-stream;base64,\(bytes.base64EncodedString())"
        )
        XCTAssertEqual(preview.data, bytes)
        XCTAssertEqual(preview.mimeType, "application/octet-stream")
        XCTAssertThrowsError(try DashboardClient.binaryPreview(fromDataURL: "not-a-data-url"))
    }

    func testAdvancedParentPathKeepsFilesystemRootStable() {
        XCTAssertEqual(DashboardClient.advancedParentPath("/repo/src"), "/repo")
        XCTAssertEqual(DashboardClient.advancedParentPath("/repo"), "/")
        XCTAssertNil(DashboardClient.advancedParentPath("/"))
    }

    func testDownloadedFilenameSanitizationRemovesHeaderInjectionCharacters() {
        XCTAssertEqual(DashboardClient.normalizedFileName("/tmp/evil\r\n\"name.txt"), "evil___name.txt")
        XCTAssertEqual(DashboardClient.normalizedFileName("/tmp/normal.pdf"), "normal.pdf")
    }

    func testMultipartBodyContainsFieldsAndOriginalBytesWithoutBase64() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "sample.bin")
        let sourceBytes = Data([0x00, 0x7f, 0xff, 0x41, 0x42])
        try sourceBytes.write(to: source)

        let boundary = "AliceBoundaryTest"
        let bodyURL = try DashboardClient.buildMultipartBody(
            source: source, path: "/remote/sample.bin", mimeType: "application/octet-stream",
            overwrite: true, boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let body = try Data(contentsOf: bodyURL)
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"path\""))
        XCTAssertTrue(text.contains("/remote/sample.bin"))
        XCTAssertTrue(text.contains("name=\"overwrite\""))
        XCTAssertTrue(text.contains("true"))
        XCTAssertTrue(text.contains("filename=\"sample.bin\""))
        XCTAssertNotNil(body.range(of: sourceBytes))
        XCTAssertFalse(text.contains(sourceBytes.base64EncodedString()))
    }
}
