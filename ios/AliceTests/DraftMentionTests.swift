import XCTest
@testable import Alice

@MainActor
final class DraftMentionTests: XCTestCase {
    private func store() throws -> (AppStore, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "alice.mention-test.\(UUID().uuidString)"))
        return (AppStore(defaults: defaults), defaults)
    }

    func testARepeatedPlainNameIsNotAnotherSelectedMention() throws {
        let (store, _) = try store()
        store.draft = "Calidad "
        store.rememberDraftMention(display: "Calidad", slug: "calidad", location: 0)
        store.draft += "Calidad"

        let ranges = store.draftMentionRanges(in: store.draft)
        XCTAssertEqual(ranges.map { NSRange($0, in: store.draft) }, [NSRange(location: 0, length: 7)])
        XCTAssertEqual(store.draftMentions.map(\.slug), ["calidad"])
    }

    func testSelectionAfterAnOrdinaryUseMarksOnlyTheChosenOccurrence() throws {
        let (store, _) = try store()
        store.draft = "Calidad Calidad "
        store.rememberDraftMention(display: "Calidad", slug: "calidad", location: 8)

        XCTAssertEqual(
            store.draftMentionRanges(in: store.draft).map { NSRange($0, in: store.draft) },
            [NSRange(location: 8, length: 7)]
        )
    }

    func testEditsBeforeTheSelectionMoveItWithoutMarkingAnotherWord() throws {
        let (store, _) = try store()
        store.draft = "👋 Calidad"
        store.rememberDraftMention(display: "Calidad", slug: "calidad", location: 3)
        store.draft = "Hola 👋 Calidad y Calidad"

        XCTAssertEqual(store.draftMentions.map(\.location), [8])
        XCTAssertEqual(store.draftMentionRanges(in: store.draft).count, 1)
    }

    func testRemovingChosenNameDoesNotPromoteThePlainRepeat() throws {
        let (store, _) = try store()
        store.draft = "Calidad y Calidad"
        store.rememberDraftMention(display: "Calidad", slug: "calidad", location: 0)
        store.draft = " y Calidad"

        XCTAssertTrue(store.draftMentions.isEmpty)
        XCTAssertTrue(store.draftMentionRanges(in: store.draft).isEmpty)
    }

    func testMessageRangesRoundTripAndOlderMessagesStillDecode() throws {
        let original = Message(
            id: "m", role: .user, content: "Calidad y Calidad", createdAt: Date(),
            mentionProfile: "calidad", selectedMentionRanges: [NSRange(location: 0, length: 7)]
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Message.self, from: data).selectedMentionRanges,
                       [NSRange(location: 0, length: 7)])

        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        archive.removeValue(forKey: "selectedMentionRanges")
        let older = try JSONSerialization.data(withJSONObject: archive)
        XCTAssertTrue(try JSONDecoder().decode(Message.self, from: older).selectedMentionRanges.isEmpty)
    }
}
