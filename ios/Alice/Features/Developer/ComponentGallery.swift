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
            id: "move", title: "Move an event",
            english: "Shall I move the haircut to Thursday at 18:00?\n[Move haircut](alice://calendar/move?title=Haircut&date=2026-09-23&time=17:00&to_date=2026-09-24&to_time=18:00)",
            spanish: "¿Paso la peluquería al jueves a las 18:00?\n[Mover peluquería](alice://calendar/move?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&to_date=2026-09-24&to_time=18:00)"
        ),
        Sample(
            id: "cancel", title: "Cancel an event",
            english: "Cancel the dentist on Friday?\n[Cancel dentist](alice://calendar/cancel?title=Dentist&date=2026-09-25&time=11:30)",
            spanish: "¿Cancelo el dentista del viernes?\n[Cancelar dentista](alice://calendar/cancel?title=Dentista&date=2026-09-25&time=11:30)"
        ),
        Sample(
            id: "connect", title: "Connect the calendar",
            english: "I can answer that once I can see your calendar.\n[Connect calendar](alice://connect/calendar)",
            spanish: "Te lo digo en cuanto pueda ver tu calendario.\n[Conectar calendario](alice://connect/calendar)"
        ),
        Sample(
            id: "places", title: "Places",
            english: "Three for dinner in Gràcia:\n```alice-ui\n{\"type\":\"places\",\"items\":[{\"title\":\"La Pubilla\",\"subtitle\":\"Market cooking, lunch only\",\"query\":\"La Pubilla Barcelona\"},{\"title\":\"Bar Bodega Quimet\",\"subtitle\":\"Vermouth and tapas since 1914\",\"query\":\"Bodega Quimet Barcelona\"}]}\n```\n[How do I get to La Pubilla?](alice://reply?text=How%20do%20I%20get%20to%20La%20Pubilla%3F)",
            spanish: "Tres para cenar en Gràcia:\n```alice-ui\n{\"type\":\"places\",\"items\":[{\"title\":\"La Pubilla\",\"subtitle\":\"Cocina de mercado, solo mediodía\",\"query\":\"La Pubilla Barcelona\"},{\"title\":\"Bar Bodega Quimet\",\"subtitle\":\"Vermut y tapas desde 1914\",\"query\":\"Bodega Quimet Barcelona\"}]}\n```\n[¿Cómo llego a La Pubilla?](alice://reply?text=%C2%BFC%C3%B3mo%20llego%20a%20La%20Pubilla%3F)"
        ),
        Sample(
            id: "map", title: "Map",
            english: "```alice-ui\n{\"type\":\"map\",\"title\":\"Near Sagrada Família\",\"places\":[{\"title\":\"Sagrada Família\",\"lat\":41.4036,\"lon\":2.1744},{\"title\":\"Hospital de Sant Pau\",\"lat\":41.4115,\"lon\":2.1744}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"map\",\"title\":\"Cerca de la Sagrada Família\",\"places\":[{\"title\":\"Sagrada Família\",\"lat\":41.4036,\"lon\":2.1744},{\"title\":\"Hospital de Sant Pau\",\"lat\":41.4115,\"lon\":2.1744}]}\n```"
        ),
        Sample(
            id: "events", title: "Events",
            english: "```alice-ui\n{\"type\":\"events\",\"items\":[{\"title\":\"Haircut\",\"start\":\"2026-09-23T17:00\",\"end\":\"2026-09-23T17:45\",\"symbol\":\"scissors\"},{\"title\":\"Dinner with Laura\",\"start\":\"2026-09-24T21:00\",\"symbol\":\"fork.knife\"}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"events\",\"items\":[{\"title\":\"Peluquería\",\"start\":\"2026-09-23T17:00\",\"end\":\"2026-09-23T17:45\",\"symbol\":\"scissors\"},{\"title\":\"Cena con Laura\",\"start\":\"2026-09-24T21:00\",\"symbol\":\"fork.knife\"}]}\n```"
        ),
        Sample(
            id: "timeline", title: "Timeline",
            english: "```alice-ui\n{\"type\":\"timeline\",\"items\":[{\"time\":\"07:10\",\"title\":\"Barcelona BCN\",\"subtitle\":\"Terminal 1 · Vueling VY1234\",\"tag\":\"On time\"},{\"time\":\"09:05\",\"title\":\"Paris ORY\",\"subtitle\":\"Orly 3\"}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"timeline\",\"items\":[{\"time\":\"07:10\",\"title\":\"Barcelona BCN\",\"subtitle\":\"Terminal 1 · Vueling VY1234\",\"tag\":\"A su hora\"},{\"time\":\"09:05\",\"title\":\"París ORY\",\"subtitle\":\"Orly 3\"}]}\n```"
        ),
        Sample(
            id: "products", title: "Products",
            english: "```alice-ui\n{\"type\":\"products\",\"items\":[{\"brand\":\"Muji\",\"title\":\"Aroma diffuser\",\"price\":\"49,95 €\"},{\"brand\":\"Hay\",\"title\":\"Kaleido tray, small\",\"price\":\"25 €\"}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"products\",\"items\":[{\"brand\":\"Muji\",\"title\":\"Difusor de aromas\",\"price\":\"49,95 €\"},{\"brand\":\"Hay\",\"title\":\"Bandeja Kaleido, pequeña\",\"price\":\"25 €\"}]}\n```"
        ),
        Sample(
            id: "phrases", title: "Phrases",
            english: "```alice-ui\n{\"type\":\"phrases\",\"language\":\"ja-JP\",\"items\":[{\"text\":\"すみません\",\"translation\":\"Excuse me\",\"note\":\"To call a waiter or get past someone\"},{\"text\":\"ありがとうございます\",\"translation\":\"Thank you very much\"}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"phrases\",\"language\":\"fr-FR\",\"items\":[{\"text\":\"Une table pour deux, s'il vous plaît\",\"translation\":\"Una mesa para dos, por favor\"},{\"text\":\"L'addition, s'il vous plaît\",\"translation\":\"La cuenta, por favor\",\"note\":\"Al terminar; no la traen si no la pides\"}]}\n```"
        ),
        Sample(
            id: "email", title: "Email draft",
            english: "```alice-ui\n{\"type\":\"email\",\"to\":\"\",\"subject\":\"Moving Thursday's meeting\",\"body\":\"Hi Laura,\\n\\nCould we move Thursday's meeting to Friday at the same time?\\n\\nThanks,\\nMarc\"}\n```",
            spanish: "```alice-ui\n{\"type\":\"email\",\"to\":\"\",\"subject\":\"Cambio de la reunión del jueves\",\"body\":\"Hola Laura,\\n\\n¿Podríamos pasar la reunión del jueves al viernes a la misma hora?\\n\\nGracias,\\nMarc\"}\n```"
        ),
        Sample(
            id: "calendar", title: "Month",
            english: "```alice-ui\n{\"type\":\"calendar\",\"month\":\"2026-09\"}\n```",
            spanish: "```alice-ui\n{\"type\":\"calendar\",\"month\":\"2026-09\"}\n```"
        ),
        Sample(
            id: "article", title: "Article",
            english: "```alice-ui\n{\"type\":\"article\",\"title\":\"Kyoto in autumn\",\"sections\":[{\"heading\":\"When\",\"text\":\"Leaves turn from **mid-November** to early December.\"},{\"heading\":\"Where\",\"text\":\"Tofuku-ji and Eikan-dō, early, before the tour groups.\"},{\"heading\":\"Tip\",\"text\":\"Book a machiya a few months ahead.\"}]}\n```",
            spanish: "```alice-ui\n{\"type\":\"article\",\"title\":\"Kioto en otoño\",\"sections\":[{\"heading\":\"Cuándo\",\"text\":\"Las hojas cambian de **mediados de noviembre** a principios de diciembre.\"},{\"heading\":\"Dónde\",\"text\":\"Tofuku-ji y Eikan-dō, temprano, antes de los grupos.\"},{\"heading\":\"Consejo\",\"text\":\"Reserva una machiya con meses de antelación.\"}]}\n```"
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
