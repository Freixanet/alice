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

    func testReEncodingStripsUnknownFields() throws {
        // This test documents the known limitation: a load → save cycle
        // through an older build strips unknown fields. It is a guard
        // against making this worse (e.g., by adding a non-optional field
        // that would cause decoding to throw instead of silently ignoring).
        let original = Data(Self.futureMessage.utf8)
        let message = try JSONDecoder().decode(Message.self, from: original)
        let reEncoded = try JSONEncoder().encode(message)
        let reDecoded = try JSONDecoder().decode(Message.self, from: reEncoded)

        // The known fields survive the round trip.
        XCTAssertEqual(message.id, reDecoded.id)
        XCTAssertEqual(message.content, reDecoded.content)

        // Unknown fields are gone after re-encoding. This is the
        // documented risk: downgrade past a field addition loses that
        // field's data. The mitigation is to keep the last known-good
        // build and not downgrade past migration boundaries.
        let originalJSON = try JSONSerialization.jsonObject(with: original) as? [String: Any]
        let reEncodedJSON = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        XCTAssertNotNil(originalJSON?["futureField"])
        XCTAssertNil(reEncodedJSON?["futureField"],
                     "re-encoding through an older build strips unknown fields — see docs/MIGRATIONS.md")
    }
}
