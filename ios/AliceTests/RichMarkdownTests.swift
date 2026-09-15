import XCTest
@testable import Alice

/// A reply is drawn as the document it is: headings, lists, callouts, code,
/// tables, formulas and reply buttons, each as a block of its own.
final class RichMarkdownTests: XCTestCase {
    func testAReplyBecomesItsBlocks() {
        let source = #"""
        ## Plan

        Primero **esto**.
        Segundo.

        - [ ] Llamar
        - [x] Escribir
          sigue

        > [!WARNING]
        > Cuidado con $x$

        ```swift
        let a = 1
        ```

        | Opción | Coste |
        | :--- | ---: |
        | A \| B | 5 € |

        ---

        $$
        \frac{a}{b}
        $$

        [Sí](alice://reply?text=Adelante)
        [No](alice://reply?text=No%20gracias)
        """#

        XCTAssertEqual(RichMarkdown.blocks(source), [
            .heading(level: 2, text: "Plan"),
            .paragraph("Primero **esto**.\nSegundo."),
            .list([
                RichListItem(depth: 0, marker: .task(done: false), text: "Llamar"),
                RichListItem(depth: 0, marker: .task(done: true), text: "Escribir\nsigue"),
            ]),
            .callout(.warning, body: "Cuidado con $x$"),
            .code(language: "swift", text: "let a = 1"),
            .table(RichTable(
                header: ["Opción", "Coste"],
                alignments: [.leading, .trailing],
                rows: [["A | B", "5 €"]]
            )),
            .rule,
            .math(#"\frac{a}{b}"#),
            .buttons([
                RichReplyButton(title: "Sí", reply: "Adelante"),
                RichReplyButton(title: "No", reply: "No gracias"),
            ]),
        ])
    }

    func testFixedFormatsStayPlainParagraphs() {
        // Chollometro's two lines per deal and Radar IA's items must not turn
        // into something else.
        let deals = "**Auriculares** — 19,99 €\nhttps://example.com/a\n\n**Teclado** — 45 €\nhttps://example.com/b"
        XCTAssertEqual(RichMarkdown.blocks(deals), [
            .paragraph("**Auriculares** — 19,99 €\nhttps://example.com/a"),
            .paragraph("**Teclado** — 45 €\nhttps://example.com/b"),
        ])
    }

    func testNumberedListsAndNesting() {
        let blocks = RichMarkdown.blocks("1. Uno\n2) Dos\n  - dentro\n\n3. Tres")
        XCTAssertEqual(blocks, [.list([
            RichListItem(depth: 0, marker: .number(1), text: "Uno"),
            RichListItem(depth: 0, marker: .number(2), text: "Dos"),
            RichListItem(depth: 1, marker: .bullet, text: "dentro"),
            RichListItem(depth: 0, marker: .number(3), text: "Tres"),
        ])])
    }

    func testAFenceStillBeingWrittenIsCode() {
        XCTAssertEqual(
            RichMarkdown.blocks("Mira:\n```python\nprint(1)"),
            [.paragraph("Mira:"), .code(language: "python", text: "print(1)")]
        )
    }

    func testAPlainQuoteIsACalloutWithoutAKind() {
        XCTAssertEqual(
            RichMarkdown.blocks("> Menos es más.\n> Siempre."),
            [.callout(nil, body: "Menos es más.\nSiempre.")]
        )
    }

    func testReplyButtonsInAListOrBesideText() {
        XCTAssertEqual(
            RichMarkdown.blocks("- [Adelante](alice://reply?text=Adelante)\n- [Espera](alice://reply)"),
            [.buttons([
                RichReplyButton(title: "Adelante", reply: "Adelante"),
                RichReplyButton(title: "Espera", reply: "Espera"),
            ])]
        )
        XCTAssertEqual(
            RichMarkdown.blocks("¿Seguimos?\n[Sí](alice://reply?text=S%C3%AD%2C%20sigue)"),
            [.paragraph("¿Seguimos?"), .buttons([RichReplyButton(title: "Sí", reply: "Sí, sigue")])]
        )
        // Ordinary links stay links.
        XCTAssertEqual(
            RichMarkdown.blocks("[Web](https://example.com)"),
            [.paragraph("[Web](https://example.com)")]
        )
    }

    func testMoneyIsNotAFormula() {
        XCTAssertEqual(RichInline.segments("Cuesta $5 y el otro $10."), [.text("Cuesta $5 y el otro $10.")])
        XCTAssertEqual(RichInline.segments("$5$"), [.text("$5$")])
        XCTAssertEqual(
            RichInline.segments("Si $x^2$ crece, <u>ojo</u>."),
            [.text("Si "), .math("x^2"), .text(" crece, "), .underline("ojo"), .text(".")]
        )
    }

    func testFormulasReadAsUnicode() {
        XCTAssertEqual(RichMath.unicode(#"\frac{LTV}{CAC} \geq 3"#), "LTV/CAC ≥ 3")
        XCTAssertEqual(RichMath.unicode(#"x^2 + \sqrt{b}"#), "x² + √b")
        XCTAssertEqual(RichMath.unicode(#"CAC = \frac{\text{gasto}}{\text{clientes}}"#), "CAC = gasto/clientes")
        XCTAssertEqual(RichMath.unicode(#"a_{n+1}"#), "aₙ₊₁")
        XCTAssertEqual(RichMath.unicode(#"\alpha \times \beta"#), "α × β")
        XCTAssertEqual(RichMath.unicode(#"\frac{a+b}{2}"#), "(a+b)/2")
    }
}
