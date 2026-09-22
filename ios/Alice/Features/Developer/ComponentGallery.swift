import SwiftUI

/// Every block a reply can be drawn with, and the cards agents can put in a
/// chat, filled with sample content — to see, in one place, in light and
/// dark, in Spanish and English, that they look right. A new block or card
/// belongs in `samples`.
struct ComponentGallery: View {
    @Environment(\.colorScheme) private var scheme
    @State private var language = ChatLanguage.spanish

    private struct Sample: Identifiable {
        let id: String
        let title: String
        let english: String
        let spanish: String
    }

    private let samples: [Sample] = [
        Sample(
            id: "text", title: "Text",
            english: "## A heading\nA paragraph with **bold**, *italic*, <u>underline</u>, `code` and a formula $E = mc^2$.\n\n- A list\n- With two items\n\n1. And a numbered one\n\n- [x] A task done\n- [ ] One to do",
            spanish: "## Un título\nUn párrafo con **negrita**, *cursiva*, <u>subrayado</u>, `código` y una fórmula $E = mc^2$.\n\n- Una lista\n- Con dos elementos\n\n1. Y una numerada\n\n- [x] Una tarea hecha\n- [ ] Una por hacer"
        ),
        Sample(
            id: "callouts", title: "Callouts",
            english: "> [!TIP]\n> Worth knowing.\n\n> [!WARNING]\n> Worth a second look.",
            spanish: "> [!TIP]\n> Conviene saberlo.\n\n> [!WARNING]\n> Merece una segunda mirada."
        ),
        Sample(
            id: "table", title: "Table",
            english: "| Option | Price | Verdict |\n| --- | ---: | --- |\n| Basic | 9 € | Enough |\n| Pro | 29 € | Best |",
            spanish: "| Opción | Precio | Veredicto |\n| --- | ---: | --- |\n| Básica | 9 € | Suficiente |\n| Pro | 29 € | La mejor |"
        ),
        Sample(
            id: "code", title: "Code",
            english: "```swift\nlet greeting = \"Hello\"\nprint(greeting)\n```",
            spanish: "```swift\nlet saludo = \"Hola\"\nprint(saludo)\n```"
        ),
        Sample(
            id: "buttons", title: "Reply buttons and links",
            english: "Shall I go ahead?\n[Yes](alice://reply?text=Yes)\n[No](alice://reply?text=No)\n\nMore in the [official announcement](https://example.com).",
            spanish: "¿Sigo adelante?\n[Sí](alice://reply?text=S%C3%AD)\n[No](alice://reply?text=No)\n\nMás en el [anuncio oficial](https://example.com)."
        ),
        Sample(
            id: "event", title: "Add to calendar",
            english: "Haircut on Wednesday. Shall I add it to your calendar?\n[Add to your calendar](alice://calendar/add?title=Haircut&date=2026-09-23)",
            spanish: "Peluquería el miércoles. ¿Lo apunto en tu calendario?\n[Añadir a tu calendario](alice://calendar/add?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&location=Gr%C3%A0cia)"
        ),
        Sample(
            id: "connect", title: "Connect the calendar",
            english: "I can answer that once I can see your calendar.\n[Connect calendar](alice://connect/calendar)",
            spanish: "Te lo digo en cuanto pueda ver tu calendario.\n[Conectar calendario](alice://connect/calendar)"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Language", selection: $language) {
                    Text("Español").tag(ChatLanguage.spanish)
                    Text("English").tag(ChatLanguage.english)
                }
                .pickerStyle(.segmented)

                ForEach(samples) { sample in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(sample.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(.tertiary)
                        RichMessageView(content: language == .spanish ? sample.spanish : sample.english)
                    }
                }

                Text("Cards here act for real: an event added from this page goes into your calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Palette.background(scheme))
        .navigationTitle("Components")
        .navigationBarTitleDisplayMode(.inline)
    }
}
