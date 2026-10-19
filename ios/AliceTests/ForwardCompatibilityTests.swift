import XCTest
@testable import Alice

/// A conversation archive written by a future build — one with fields this
/// build does not know — must not lose those fields when it is loaded and
/// re-saved.
///
/// Swift's synthesized `JSONDecoder` silently ignores unknown keys. But
/// `JSONEncoder` only encodes the fields it knows. So a load → save cycle
/// through an older build strips every field that build does not recognize.
/// If that happens, the data is gone: the next launch reads the stripped
/// archive and there is nothing to recover.
///
/// This test does not fix that (it cannot, without a schema change). It
/// documents the risk and guards against accidentally making it worse: if
/// someone adds a field and makes it non-optional, this test fails before
/// the regression ships.
///
/// The companion documentation is in docs/MIGRATIONS.md and
/// docs/DATA_INTEGRITY.md.
final class ForwardCompatibilityTests: XCTestCase {

    /// A message from a hypothetical future build, with fields this build
    /// does not recognize.
    private static let futureMessage = """
    {"id":"m1","role":"user","content":"hola","createdAt":768000000,
     "pending":false,"tools":[],"incomplete":false,"attachments":[],
     "futureField":"important future data",
     "anotherFutureField":42}
    """

    /// A conversation from a hypothetical future build.
    private static let futureConversation = """
    {"id":"c1","title":"Future chat","createdAt":768000000,"updatedAt":768000100,
     "pinned":false,"isChannel":false,"channelBots":[],"messages":[
     {"id":"m1","role":"user","content":"hola","createdAt":768000000,
      "pending":false,"tools":[],"incomplete":false,"attachments":[],
      "futureField":"important future data"}
     ],
     "futureConvField":"more future data"}
    """

    func testAFutureMessageDecodes() throws {
        let message = try JSONDecoder().decode(
            Message.self,
            from: Data(Self.futureMessage.utf8)
        )

        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.content, "hola")
        // The unknown fields are silently ignored. This is the expected
        // behavior for forward compatibility — the build can still read
        // the conversation. The risk is on the re-save path (see below).
    }

    func testAFutureConversationDecodes() throws {
        let conversation = try JSONDecoder().decode(
            Conversation.self,
            from: Data(Self.futureConversation.utf8)
        )

        XCTAssertEqual(conversation.id, "c1")
        XCTAssertEqual(conversation.title, "Future chat")
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.content, "hola")
    }

    func testKnownFieldsSurviveReEncoding() throws {
        // A load → save cycle through this build must preserve every field
        // the build knows. This is the invariant that matters: if a future
        // build adds a field and this build loads and re-saves, the known
        // fields survive. Unknown fields (fields this build does not
        // recognize) are silently dropped by JSONEncoder — that is a
        // known limitation documented in docs/MIGRATIONS.md, not a
        // behavior to assert here.
        let original = Data(Self.futureMessage.utf8)
        let message = try JSONDecoder().decode(Message.self, from: original)
        let reEncoded = try JSONEncoder().encode(message)
        let reDecoded = try JSONDecoder().decode(Message.self, from: reEncoded)

        // Every field this build knows must survive the round trip.
        XCTAssertEqual(message.id, reDecoded.id)
        XCTAssertEqual(message.content, reDecoded.content)
        XCTAssertEqual(message.role, reDecoded.role)
        XCTAssertEqual(message.createdAt, reDecoded.createdAt)
        XCTAssertEqual(message.pending, reDecoded.pending)
        XCTAssertEqual(message.tools, reDecoded.tools)
        XCTAssertEqual(message.incomplete, reDecoded.incomplete)
        XCTAssertEqual(message.attachments, reDecoded.attachments)
    }
}
