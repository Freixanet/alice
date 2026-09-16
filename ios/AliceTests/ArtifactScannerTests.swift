import XCTest
@testable import Alice

/// Library shows what the agent made, not everything it touched. A file only
/// read is not the agent's work, and neither is a link buried in search results.
final class ArtifactScannerTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_789_500_000)

    private func tool(_ name: String, _ content: String) -> HermesClient.StoredMessage {
        HermesClient.StoredMessage(role: "tool", content: content, toolName: name, timestamp: when)
    }

    private func said(_ content: String) -> HermesClient.StoredMessage {
        HermesClient.StoredMessage(role: "assistant", content: content, toolName: nil, timestamp: when)
    }

    func testAFileTheAgentWroteOrPatchedIsKept() {
        let found = ArtifactScanner.scan([
            tool("write_file", #"{"success": true, "path": "/Users/me/Documents/informe.pdf"}"#),
            tool("patch", #"{"success": true, "path": "/Users/me/alice/notas.md"}"#),
        ], session: "Informe")
        XCTAssertEqual(Set(found.map(\.value)), [
            "/Users/me/Documents/informe.pdf", "/Users/me/alice/notas.md",
        ])
        XCTAssertTrue(found.allSatisfy { $0.kind == .file && $0.session == "Informe" })
    }

    func testAFileTheAgentOnlyReadOrSearchedIsLeftOut() {
        let found = ArtifactScanner.scan([
            tool("read_file", "See /Users/me/alice/README.md and /Users/me/alice/plan.md"),
            tool("search_files", "/Users/me/alice/Sources/App.swift:12: func run()"),
            tool("terminal", "wrote /Users/me/tmp/output.csv"),
        ], session: "Lectura")
        XCTAssertTrue(found.isEmpty, "\(found.map(\.value))")
    }

    func testAnImageTheAgentGeneratedIsAnImage() {
        let found = ArtifactScanner.scan([
            tool("image_generate", #"{"image_path": "/Users/me/Pictures/logo.png"}"#),
        ], session: "Logo")
        XCTAssertEqual(found.map(\.kind), [.image])
    }

    func testLinksComeOnlyFromWhatTheAgentSaid() {
        let found = ArtifactScanner.scan([
            said("Aquí tienes la fuente: https://nousresearch.com/releases."),
            tool("web_search", "https://example.com/result-1 https://example.com/result-2"),
        ], session: "Noticias")
        XCTAssertEqual(found.map(\.value), ["https://nousresearch.com/releases"])
    }

    func testPrivateAndSystemFilesStayOutEvenWhenWritten() {
        let found = ArtifactScanner.scan([
            tool("write_file", #"{"path": "/Users/me/.hermes/auth.json"}"#),
            tool("write_file", #"{"path": "/Users/me/Library/Caches/tmp.json"}"#),
        ], session: "Ajustes")
        XCTAssertTrue(found.isEmpty, "\(found.map(\.value))")
    }
}
