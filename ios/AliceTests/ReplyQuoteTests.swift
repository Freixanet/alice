import Foundation
import Testing
@testable import Alice

struct ReplyQuoteTests {
    @Test func quotesTheReplyOnOneLineAboveTheWords() {
        let quote = ReplyQuote(messageID: "a", author: "Alice", content: "**Hola**\n\nTe recuerdo\nmañana.")
        #expect(quote.excerpt == "Hola Te recuerdo mañana.")
        let sent = quote.prefix + "¿A qué hora?"
        let split = ReplyQuote.split(sent)
        #expect(split?.quote == "Hola Te recuerdo mañana.")
        #expect(split?.text == "¿A qué hora?")
    }

    @Test func cutsALongReplyAtAWord() {
        let long = String(repeating: "palabra ", count: 80)
        let excerpt = ReplyQuote.excerpt(long)
        #expect(excerpt.count <= ReplyQuote.excerptLimit + 1)
        #expect(excerpt.hasSuffix("…"))
    }

    @Test func plainMessagesAreNotQuotes() {
        #expect(ReplyQuote.split("hola") == nil)
        #expect(ReplyQuote.split("> solo una cita") == nil)
    }

    @Test func mentionsMoveOntoTheOwnWords() {
        let content = ReplyQuote(messageID: "a", author: "Alice", content: "Hecho").prefix + "@maria mira"
        let shift = content.utf16.count - "@maria mira".utf16.count
        let moved = ReplyQuote.ranges([NSRange(location: shift, length: 6)], in: content)
        #expect(moved == [NSRange(location: 0, length: 6)])
    }
}
