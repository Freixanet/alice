import XCTest
@testable import Alice

final class AliceBuildInfoTests: XCTestCase {
    func testBuildInfoFormatsVersionAndShortRevision() {
        let info = AliceBuildInfo.from([
            "CFBundleShortVersionString": "1.2",
            "CFBundleVersion": "456",
            "AliceSourceRevision": "e4ba889536467eb42ad0c4cdbb253fdf19858a6d",
        ])
        XCTAssertEqual(info.versionLabel, "1.2 (456)")
        XCTAssertEqual(info.revision, "e4ba8895")
    }

    func testDevelopmentRevisionIsNotPresentedAsACommit() {
        let info = AliceBuildInfo.from([
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "2",
            "AliceSourceRevision": "development",
        ])
        XCTAssertNil(info.revision)
    }
}
