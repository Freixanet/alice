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
            .paragraph("Primero **esto**. Segundo."),
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

    func testFixedFormatsKeepTheirLinesAndTheirAddressesBecomeButtons() {
        // Chollometro's two lines per deal and Radar IA's items keep their
        // shape; the address under each is a button, not text.
        let deals = "**Auriculares** — 19,99 €\nhttps://example.com/a\n\n**Teclado** — 45 €\nhttps://www.example.com/b"
        XCTAssertEqual(RichMarkdown.blocks(deals), [
            .paragraph("**Auriculares** — 19,99 €"),
            .links([RichLink(title: "example.com", url: URL(string: "https://example.com/a")!)]),
            .paragraph("**Teclado** — 45 €"),
            .links([RichLink(title: "example.com", url: URL(string: "https://www.example.com/b")!)]),
        ])
    }

    func testLinksAreButtonsAndNeverAddressesInTheText() {
        let source = """
        Lee el [anuncio oficial](https://openai.com/blog/x) antes de decidir.
        Fuente: https://www.reuters.com/tech/y
        Usa `curl https://api.example.com` para probar.
        """
        XCTAssertEqual(RichMarkdown.blocks(source), [
            .paragraph("Lee el anuncio oficial antes de decidir. Usa `curl https://api.example.com` para probar."),
            .links([
                RichLink(title: "anuncio oficial", url: URL(string: "https://openai.com/blog/x")!),
                RichLink(title: "reuters.com", url: URL(string: "https://www.reuters.com/tech/y")!),
            ]),
        ])
        XCTAssertEqual(
            RichMarkdown.blocks("- Precio en https://shop.example.com/p\n- Otra vez https://shop.example.com/p\n- Sin enlace"),
            [
                .list([
                    RichListItem(depth: 0, marker: .bullet, text: "Precio en"),
                    RichListItem(depth: 0, marker: .bullet, text: "Otra vez"),
                    RichListItem(depth: 0, marker: .bullet, text: "Sin enlace"),
                ]),
                .links([RichLink(title: "shop.example.com", url: URL(string: "https://shop.example.com/p")!)]),
            ]
        )
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

    func testAnUnknownCalloutKindIsDroppedNotHalfDrawn() {
        XCTAssertEqual(
            RichMarkdown.blocks("> [!TIMELINE]\n> Ayer, luego hoy.\n\nSigue."),
            [.paragraph("Ayer, luego hoy."), .paragraph("Sigue.")]
        )
        XCTAssertEqual(
            RichMarkdown.blocks("> [!quiz] Elige una"),
            [.paragraph("Elige una")]
        )
        XCTAssertTrue(RichMarkdown.blocks("> [!stat]").isEmpty)
        XCTAssertEqual(
            RichMarkdown.blocks("> [!WARNING]\n> De verdad"),
            [.callout(.warning, body: "De verdad")]
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
        // A web link is a button of its own, not a reply.
        XCTAssertEqual(
            RichMarkdown.blocks("[Web](https://example.com)"),
            [.links([RichLink(title: "Web", url: URL(string: "https://example.com")!)])]
        )
    }

    func testStackedLinesJoinAndOnlyAWallIsSplit() {
        XCTAssertEqual(
            RichMarkdown.blocks("Uno.\nDos.\nTres."),
            [.paragraph("Uno. Dos. Tres.")]
        )
        XCTAssertEqual(
            RichMarkdown.blocks("Uno.\n\nDos."),
            [.paragraph("Uno."), .paragraph("Dos.")]
        )
        let wall = "La hipótesis más arriesgada es que las personas mayores no abrirán una app de pastillas porque el nieto gestiona todo. El experimento más barato esta semana es hablar con ocho nietos y preguntar quién recuerda las tomas. Si nadie lo hace por ellos, la idea vive; si el cuidador ya cubre eso, se descarta."
        let runs = RichMarkdown.paragraphRuns(wall)
        XCTAssertEqual(runs.count, 3)
        XCTAssertTrue(runs[0].hasPrefix("La hipótesis"))
        XCTAssertTrue(runs[1].hasPrefix("El experimento"))
        XCTAssertTrue(runs[2].hasPrefix("Si nadie"))
        let titled = "El Sr. García confirma que la clínica pequeña sí pierde citas cada semana y que el recepcionista no da abasto con las llamadas de la tarde ni con los no-shows del lunes por la mañana."
        XCTAssertGreaterThanOrEqual(titled.count, 180)
        XCTAssertEqual(RichMarkdown.paragraphRuns(titled), [titled])
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
