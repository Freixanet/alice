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
}
