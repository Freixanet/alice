import SwiftUI

/// Every block a reply can be drawn with and every card that can appear in a chat, filled with
/// sample content — to see, in one place, in light and dark, in Spanish and English, that they
/// look right. A new block or card is a new case of `GallerySample`; a test checks each one
/// draws something.
///
/// The samples are the app's own views (`MessageRow` for anything a reply carries) on a sandbox
/// store with nothing behind it (`GalleryFixtures.sandbox`): tapping a card does not send,
/// approve, save or pay anything. Calendar cards are the exception — they use this iPhone's own
/// calendar, as they would in a chat.
struct ComponentGallery: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var language = ChatLanguage.spanish
    @State private var sandbox: AppStore?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                Picker("Language", selection: $language) {
                    Text("Español").tag(ChatLanguage.spanish)
                    Text("English").tag(ChatLanguage.english)
                }
                .pickerStyle(.segmented)

                if let sandbox {
                    ForEach(GallerySection.allCases) { section in
                        Text(section.title(language))
                            .font(.title3.weight(.semibold))
                            .padding(.top, 8)
                        ForEach(GallerySample.allCases.filter { $0.section == section }) { sample in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(sample.title.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(.tertiary)
                                GallerySampleView(sample: sample, language: language)
                            }
                        }
                    }
                    .environment(sandbox)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }

                Text(language.pick(
                    "Nothing here reaches Hermes: buttons, approvals and payments have nowhere to go. Calendar cards use this iPhone's calendar, as in a chat.",
                    "Nada de aquí llega a Hermes: botones, aprobaciones y pagos no tienen adónde ir. Las tarjetas de calendario usan el calendario de este iPhone, como en un chat."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Palette.background(scheme))
        .navigationTitle(language.pick("Components", "Componentes"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if sandbox == nil { sandbox = GalleryFixtures.sandbox(like: store) }
        }
    }
}

enum GallerySection: String, CaseIterable, Identifiable {
    case text, cards, choices, approvals, purchase, browser, agents, chrome

    var id: String { rawValue }

    func title(_ language: ChatLanguage) -> String {
        switch self {
        case .text: language.pick("Text and blocks", "Texto y bloques")
        case .cards: language.pick("Cards", "Tarjetas")
        case .choices: language.pick("Choices and questions", "Opciones y preguntas")
        case .approvals: language.pick("Approvals", "Aprobaciones")
        case .purchase: language.pick("Purchase", "Compra")
        case .browser: language.pick("Browser", "Navegador")
        case .agents: language.pick("Agents and routines", "Agentes y rutinas")
        case .chrome: language.pick("Around a message", "Alrededor del mensaje")
        }
    }
}

/// What a sample is drawn from.
enum GalleryContent {
    /// A reply's text, as `RichMessageView` draws it.
    case markdown(String)
    /// Whole turns, as `MessageRow` draws them in a chat.
    case messages([Message])
    /// A card a chat shows beside the turns (errands, the checkout).
    case view(AnyView)
}

enum GallerySample: String, CaseIterable, Identifiable {
    // Text and blocks
    case text, callouts, table, code, math, links, media, receipts
    // Cards
    case event, move, cancel, connect, places, map, events, timeline, products, phrases, email, month, article
    case spending, secretKey, health, paymentCardOffer
    // Choices and questions
    case replyButtons, dottedButtons, filledButtons, slashChoices, askPerson, errandQuestions, capsuleButtons
    // Approvals
    case runApproval, paymentApproval, errandConfirm, checkoutPending, checkoutApproved, checkoutExpired
    // Purchase
    case purchaseOptions, purchaseChosen, purchaseSummary, purchaseResult, purchaseDeclined, purchaseUnknown, purchaseStopped
    case productSheet, errandWorking, errandStuck, receipt, errandList, cardBadges
    // Browser
    case liveBrowser, errandBrowser
    // Agents and routines
    case trace, plan, routine, agentMessage, feedContext, modelLimit
    // Around a message
    case userMessage, reaction, attachment, streaming, failed

    var id: String { rawValue }

    var section: GallerySection {
        switch self {
        case .text, .callouts, .table, .code, .math, .links, .media, .receipts: .text
        case .event, .move, .cancel, .connect, .places, .map, .events, .timeline, .products, .phrases, .email,
             .month, .article, .spending, .secretKey, .health, .paymentCardOffer: .cards
        case .replyButtons, .dottedButtons, .filledButtons, .slashChoices, .askPerson, .errandQuestions, .capsuleButtons: .choices
        case .runApproval, .paymentApproval, .errandConfirm, .checkoutPending, .checkoutApproved, .checkoutExpired:
            .approvals
        case .purchaseOptions, .purchaseChosen, .purchaseSummary, .purchaseResult, .purchaseDeclined, .purchaseUnknown, .purchaseStopped,
             .productSheet, .errandWorking, .errandStuck, .receipt, .errandList, .cardBadges: .purchase
        case .liveBrowser, .errandBrowser: .browser
        case .trace, .plan, .routine, .agentMessage, .feedContext, .modelLimit: .agents
        case .userMessage, .reaction, .attachment, .streaming, .failed: .chrome
        }
    }

    var title: String {
        switch self {
        case .text: "Text"
        case .callouts: "Callouts"
        case .table: "Table"
        case .code: "Code"
        case .math: "Formula and rule"
        case .links: "Links and sources"
        case .media: "Media"
        case .receipts: "Session receipts"
        case .event: "Add to calendar"
        case .move: "Move an event"
        case .cancel: "Cancel an event"
        case .connect: "Connect the calendar"
        case .places: "Places"
        case .map: "Map"
        case .events: "Events"
        case .timeline: "Timeline"
        case .products: "Products"
        case .phrases: "Phrases"
        case .email: "Email draft"
        case .month: "Month"
        case .article: "Article"
        case .spending: "Spending"
        case .secretKey: "Secret key"
        case .health: "Connect Health"
        case .paymentCardOffer: "Add a payment card"
        case .replyButtons: "Suggested replies"
        case .dottedButtons: "Options (dotted)"
        case .filledButtons: "Options (filled, centred)"
        case .slashChoices: "Command choices"
        case .askPerson: "Questions while working (ask_person)"
        case .errandQuestions: "An errand's questions"
        case .capsuleButtons: "Capsule buttons"
        case .runApproval: "Run approval"
        case .paymentApproval: "Card fill approval"
        case .errandConfirm: "Errand confirmation"
        case .checkoutPending: "Checkout · waiting"
        case .checkoutApproved: "Checkout · approved"
        case .checkoutExpired: "Checkout · expired"
        case .purchaseOptions: "Verified purchase options"
        case .purchaseChosen: "Chosen purchase option"
        case .purchaseSummary: "Purchase summary"
        case .purchaseResult: "Purchase result in chat"
        case .purchaseDeclined: "Declined payment in chat"
        case .purchaseUnknown: "Unconfirmed payment in chat"
        case .purchaseStopped: "Stopped purchase in chat"
        case .productSheet: "Product sheet"
        case .errandWorking: "Errand at work"
        case .errandStuck: "Errand stuck"
        case .receipt: "Receipt"
        case .errandList: "Errands list"
        case .cardBadges: "Card brands"
        case .liveBrowser: "Live browser"
        case .errandBrowser: "Errand's browser"
        case .trace: "Steps and reasoning"
        case .plan: "Plan"
        case .routine: "Routine report"
        case .agentMessage: "Another agent's message"
        case .feedContext: "From your feed"
        case .modelLimit: "Model limit"
        case .userMessage: "Your message"
        case .reaction: "Reaction"
        case .attachment: "Attachment"
        case .streaming: "Reply arriving"
        case .failed: "Failed reply"
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @MainActor func content(_ language: ChatLanguage) -> GalleryContent {
        let pick = language.pick
        typealias F = GalleryFixtures
        switch self {
        case .text:
            return .markdown(pick(
                "## A heading\nA paragraph with **bold**, *italic*, <u>underline</u>, `code` and a formula $E = mc^2$.\n\n- A list\n- With two items\n\n1. And a numbered one\n\n- [x] A task done\n- [ ] One to do",
                "## Un título\nUn párrafo con **negrita**, *cursiva*, <u>subrayado</u>, `código` y una fórmula $E = mc^2$.\n\n- Una lista\n- Con dos elementos\n\n1. Y una numerada\n\n- [x] Una tarea hecha\n- [ ] Una por hacer"))
        case .callouts:
            return .markdown(pick(
                "> [!NOTE]\n> For the record.\n\n> [!TIP]\n> Worth knowing.\n\n> [!IMPORTANT]\n> Do not skip this.\n\n> [!WARNING]\n> Worth a second look.\n\n> [!CAUTION]\n> This cannot be undone.",
                "> [!NOTE]\n> Para que conste.\n\n> [!TIP]\n> Conviene saberlo.\n\n> [!IMPORTANT]\n> No te lo saltes.\n\n> [!WARNING]\n> Merece una segunda mirada.\n\n> [!CAUTION]\n> No se puede deshacer."))
        case .table:
            return .markdown(pick(
                "| Option | Price | Verdict |\n| --- | ---: | --- |\n| Basic | 9 € | Enough |\n| Pro | 29 € | Best |",
                "| Opción | Precio | Veredicto |\n| --- | ---: | --- |\n| Básica | 9 € | Suficiente |\n| Pro | 29 € | La mejor |"))
        case .code:
            return .markdown(pick("```swift\nlet greeting = \"Hello\"\nprint(greeting)\n```",
                                  "```swift\nlet saludo = \"Hola\"\nprint(saludo)\n```"))
        case .math:
            return .markdown(pick("The area of a circle:\n\n$$A = \\pi r^2$$\n\n---\n\nAnd below the rule, the rest.",
                                  "El área de un círculo:\n\n$$A = \\pi r^2$$\n\n---\n\nY bajo la línea, lo demás."))
        case .links:
            return .markdown(pick(
                "Apple moved Siri to a new model.[1]\n\nhttps://www.apple.com/newsroom/\n\nSources\n1. [Apple Newsroom](https://www.apple.com/newsroom/)\n2. [Reuters](https://www.reuters.com/technology/)",
                "Apple ha pasado Siri a un modelo nuevo.[1]\n\nhttps://www.apple.com/newsroom/\n\nFuentes\n1. [Apple Newsroom](https://www.apple.com/newsroom/)\n2. [Reuters](https://www.reuters.com/technology/)"))
        case .media:
            return .markdown("![alice.png](https://raw.githubusercontent.com/Freixanet/alice/main/public/favicon.png)")
        case .receipts:
            return .markdown(pick("As we said yesterday (@session:gallery-session).",
                                  "Como dijimos ayer (@session:gallery-session)."))
        case .event:
            return .markdown(pick(
                "Haircut on Wednesday. Shall I add it to your calendar?\n[Add to your calendar](alice://calendar/add?title=Haircut&date=2026-09-23)",
                "Peluquería el miércoles. ¿Lo apunto en tu calendario?\n[Añadir a tu calendario](alice://calendar/add?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&location=Gr%C3%A0cia)"))
        case .move:
            return .markdown(pick(
                "Shall I move the haircut to Thursday at 18:00?\n[Move haircut](alice://calendar/move?title=Haircut&date=2026-09-23&time=17:00&to_date=2026-09-24&to_time=18:00)",
                "¿Paso la peluquería al jueves a las 18:00?\n[Mover peluquería](alice://calendar/move?title=Peluquer%C3%ADa&date=2026-09-23&time=17:00&to_date=2026-09-24&to_time=18:00)"))
        case .cancel:
            return .markdown(pick(
                "Cancel the dentist on Friday?\n[Cancel dentist](alice://calendar/cancel?title=Dentist&date=2026-09-25&time=11:30)",
                "¿Cancelo el dentista del viernes?\n[Cancelar dentista](alice://calendar/cancel?title=Dentista&date=2026-09-25&time=11:30)"))
        case .connect:
            return .markdown(pick("I can answer that once I can see your calendar.\n[Connect calendar](alice://connect/calendar)",
                                  "Te lo digo en cuanto pueda ver tu calendario.\n[Conectar calendario](alice://connect/calendar)"))
        case .places:
            return .markdown(pick(
                "Three for dinner in Gràcia:\n```alice-ui\n{\"type\":\"places\",\"items\":[{\"title\":\"La Pubilla\",\"subtitle\":\"Market cooking, lunch only\",\"query\":\"La Pubilla Barcelona\"},{\"title\":\"Bar Bodega Quimet\",\"subtitle\":\"Vermouth and tapas since 1914\",\"query\":\"Bodega Quimet Barcelona\"}]}\n```",
                "Tres para cenar en Gràcia:\n```alice-ui\n{\"type\":\"places\",\"items\":[{\"title\":\"La Pubilla\",\"subtitle\":\"Cocina de mercado, solo mediodía\",\"query\":\"La Pubilla Barcelona\"},{\"title\":\"Bar Bodega Quimet\",\"subtitle\":\"Vermut y tapas desde 1914\",\"query\":\"Bodega Quimet Barcelona\"}]}\n```"))
        case .map:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"map\",\"title\":\"Near Sagrada Família\",\"places\":[{\"title\":\"Sagrada Família\",\"lat\":41.4036,\"lon\":2.1744},{\"title\":\"Hospital de Sant Pau\",\"lat\":41.4115,\"lon\":2.1744}]}\n```",
                "```alice-ui\n{\"type\":\"map\",\"title\":\"Cerca de la Sagrada Família\",\"places\":[{\"title\":\"Sagrada Família\",\"lat\":41.4036,\"lon\":2.1744},{\"title\":\"Hospital de Sant Pau\",\"lat\":41.4115,\"lon\":2.1744}]}\n```"))
        case .events:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"events\",\"items\":[{\"title\":\"Haircut\",\"start\":\"2026-09-23T17:00\",\"end\":\"2026-09-23T17:45\",\"symbol\":\"scissors\"},{\"title\":\"Dinner with Laura\",\"start\":\"2026-09-24T21:00\",\"symbol\":\"fork.knife\"}]}\n```",
                "```alice-ui\n{\"type\":\"events\",\"items\":[{\"title\":\"Peluquería\",\"start\":\"2026-09-23T17:00\",\"end\":\"2026-09-23T17:45\",\"symbol\":\"scissors\"},{\"title\":\"Cena con Laura\",\"start\":\"2026-09-24T21:00\",\"symbol\":\"fork.knife\"}]}\n```"))
        case .timeline:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"timeline\",\"items\":[{\"time\":\"07:10\",\"title\":\"Barcelona BCN\",\"subtitle\":\"Terminal 1 · Vueling VY1234\",\"tag\":\"On time\"},{\"time\":\"09:05\",\"title\":\"Paris ORY\",\"subtitle\":\"Orly 3\"}]}\n```",
                "```alice-ui\n{\"type\":\"timeline\",\"items\":[{\"time\":\"07:10\",\"title\":\"Barcelona BCN\",\"subtitle\":\"Terminal 1 · Vueling VY1234\",\"tag\":\"A su hora\"},{\"time\":\"09:05\",\"title\":\"París ORY\",\"subtitle\":\"Orly 3\"}]}\n```"))
        case .products:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"products\",\"items\":[{\"brand\":\"Muji\",\"title\":\"Aroma diffuser\",\"price\":\"49,95 €\"},{\"brand\":\"Hay\",\"title\":\"Kaleido tray, small\",\"price\":\"25 €\"}]}\n```",
                "```alice-ui\n{\"type\":\"products\",\"items\":[{\"brand\":\"Muji\",\"title\":\"Difusor de aromas\",\"price\":\"49,95 €\"},{\"brand\":\"Hay\",\"title\":\"Bandeja Kaleido, pequeña\",\"price\":\"25 €\"}]}\n```"))
        case .phrases:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"phrases\",\"language\":\"ja-JP\",\"items\":[{\"text\":\"すみません\",\"translation\":\"Excuse me\",\"note\":\"To call a waiter or get past someone\"},{\"text\":\"ありがとうございます\",\"translation\":\"Thank you very much\"}]}\n```",
                "```alice-ui\n{\"type\":\"phrases\",\"language\":\"fr-FR\",\"items\":[{\"text\":\"Une table pour deux, s'il vous plaît\",\"translation\":\"Una mesa para dos, por favor\"},{\"text\":\"L'addition, s'il vous plaît\",\"translation\":\"La cuenta, por favor\",\"note\":\"Al terminar; no la traen si no la pides\"}]}\n```"))
        case .email:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"email\",\"to\":\"\",\"subject\":\"Moving Thursday's meeting\",\"body\":\"Hi Laura,\\n\\nCould we move Thursday's meeting to Friday at the same time?\\n\\nThanks,\\nMarc\"}\n```",
                "```alice-ui\n{\"type\":\"email\",\"to\":\"\",\"subject\":\"Cambio de la reunión del jueves\",\"body\":\"Hola Laura,\\n\\n¿Podríamos pasar la reunión del jueves al viernes a la misma hora?\\n\\nGracias,\\nMarc\"}\n```"))
        case .month:
            return .markdown("```alice-ui\n{\"type\":\"calendar\",\"month\":\"2026-09\"}\n```")
        case .article:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"article\",\"title\":\"Kyoto in autumn\",\"sections\":[{\"heading\":\"When\",\"text\":\"Leaves turn from **mid-November** to early December.\"},{\"heading\":\"Where\",\"text\":\"Tofuku-ji and Eikan-dō, early, before the tour groups.\"}]}\n```",
                "```alice-ui\n{\"type\":\"article\",\"title\":\"Kioto en otoño\",\"sections\":[{\"heading\":\"Cuándo\",\"text\":\"Las hojas cambian de **mediados de noviembre** a principios de diciembre.\"},{\"heading\":\"Dónde\",\"text\":\"Tofuku-ji y Eikan-dō, temprano, antes de los grupos.\"}]}\n```"))
        case .spending:
            return .markdown(pick(
                "```alice-ui\n{\"type\":\"spending\",\"income\":2400,\"spent\":1730.5,\"net\":669.5,\"currency\":\"EUR\",\"from\":\"2026-09-01\",\"to\":\"2026-09-30\",\"categories\":[{\"name\":\"Home\",\"amount\":820},{\"name\":\"Food\",\"amount\":410.5},{\"name\":\"Transport\",\"amount\":180}]}\n```",
                "```alice-ui\n{\"type\":\"spending\",\"income\":2400,\"spent\":1730.5,\"net\":669.5,\"currency\":\"EUR\",\"from\":\"2026-09-01\",\"to\":\"2026-09-30\",\"categories\":[{\"name\":\"Casa\",\"amount\":820},{\"name\":\"Comida\",\"amount\":410.5},{\"name\":\"Transporte\",\"amount\":180}]}\n```"))
        case .secretKey:
            return .markdown(pick("Searching needs an Exa key.\n[Add the key](alice://connect/secret/EXA_API_KEY)",
                                  "Para buscar hace falta una clave de Exa.\n[Añadir la clave](alice://connect/secret/EXA_API_KEY)"))
        case .health:
            return .markdown(pick("I can read your sleep once Health is connected.\n[Connect Health](alice://connect/health)",
                                  "Puedo leer tu sueño en cuanto conectes Salud.\n[Conectar Salud](alice://connect/health)"))
        case .paymentCardOffer:
            return .markdown(pick("There is no card saved for this shop yet.\n[Add a card](alice://connect/card?origin=https%3A%2F%2Fwww.hsnstore.com&profile=default)",
                                  "Aún no hay tarjeta guardada para esta tienda.\n[Añadir tarjeta](alice://connect/card?origin=https%3A%2F%2Fwww.hsnstore.com&profile=default)"))
        case .replyButtons:
            return .markdown(pick("Shall I go ahead?\n[Yes](alice://reply?text=Yes)\n[No](alice://reply?text=No)",
                                  "¿Sigo adelante?\n[Sí](alice://reply?text=S%C3%AD)\n[No](alice://reply?text=No)"))
        case .dottedButtons:
            return .markdown(pick(
                "Which model?\n[iPhone 17](alice://reply?text=iPhone%2017&style=dotted)\n[iPhone 17 Pro](alice://reply?text=iPhone%2017%20Pro&style=dotted)",
                "¿Qué modelo?\n[iPhone 17](alice://reply?text=iPhone%2017&style=dotted)\n[iPhone 17 Pro](alice://reply?text=iPhone%2017%20Pro&style=dotted)"))
        case .filledButtons:
            return .markdown(pick(
                "Which size?\n[S](alice://reply?text=S&style=filled)\n[M](alice://reply?text=M&style=filled)\n[L](alice://reply?text=L&style=filled)",
                "¿Qué talla?\n[S](alice://reply?text=S&style=filled)\n[M](alice://reply?text=M&style=filled)\n[L](alice://reply?text=L&style=filled)"))
        case .slashChoices:
            var message = F.reply("slash", pick("Reasoning effort:", "Esfuerzo de razonamiento:"))
            message.slashChoices = [
                SlashChoice(label: pick("Low", "Bajo"), command: "/reasoning low", current: false),
                SlashChoice(label: pick("Medium", "Medio"), command: "/reasoning medium", current: true),
                SlashChoice(label: pick("High", "Alto"), command: "/reasoning high", current: false),
            ]
            return .messages([message])
        case .askPerson:
            let detail = pick(
                #"{"title":"Before I go on","questions":[{"id":"size","question":"Which size?","choices":["S","M","L"]},{"id":"address","question":"Deliver to which address?","field":"address"}]}"#,
                #"{"title":"Antes de seguir","questions":[{"id":"talla","question":"¿Qué talla?","choices":["S","M","L"]},{"id":"direccion","question":"¿A qué dirección lo envío?","field":"address"}]}"#)
            return .messages([F.reply("ask", pick("I'll keep looking meanwhile.", "Mientras, sigo buscando."),
                                      tools: [F.tool("ask-1", AskPerson.toolName, detail)])])
        case .errandQuestions:
            return .view(AnyView(ErrandQuestionsCard(
                errand: F.errand(language, status: .needsInput, questions: F.errandQuestions(language)),
                onAnswer: { _ in })))
        case .capsuleButtons:
            return .view(AnyView(HStack(spacing: 10) {
                PurchaseCapsuleButton(title: pick("Deny", "Denegar"), action: {})
                PurchaseCapsuleButton(title: pick("Allow", "Permitir"), prominent: true, symbol: Biometrics.symbol,
                                      tint: .approve, action: {})
            }))
        case .runApproval:
            let approval = Message.Approval(
                runID: "gallery-run", title: "terminal",
                detail: pick("Deletes a folder", "Borra una carpeta"),
                command: "rm -rf ~/Downloads/old", choices: [.once, .session, .always, .deny])
            return .messages([F.reply("run-approval", "", pending: true,
                                      tools: [F.tool("t1", "terminal", "rm -rf ~/Downloads/old", done: false)],
                                      approval: approval)])
        case .paymentApproval:
            let approval = Message.Approval(
                runID: "gallery-pay", title: "Approval needed", detail: nil,
                command: "Fill payment card 'Visa ···4242' on https://www.hsnstore.com", choices: [.once, .deny])
            return .messages([F.reply("pay-approval", pick("Creatine 27.98 € at HSN, arriving Friday.",
                                                           "Creatina 27,98 € en HSN, llega el viernes."),
                                      pending: true, approval: approval)])
        case .errandConfirm:
            return .view(AnyView(ErrandConfirmCard(
                approval: Errand.Approval(requestID: "gallery", title: pick("Sign in to HSN with the saved account",
                                                                            "Entrar en HSN con la cuenta guardada")),
                language: language, onAllow: {}, onDeny: {})))
        case .checkoutPending:
            return .view(AnyView(CheckoutApprovalCard(
                checkout: F.checkout(language), language: language, compact: true, onOpenPage: {},
                cards: [SavedCard.demo(origin: nil)], chosenCard: SavedCard.demo(origin: nil),
                onAllow: {}, onDeny: {})))
        case .checkoutApproved:
            return .view(AnyView(CheckoutApprovalCard(
                checkout: F.checkout(language, status: .approved), language: language, phase: .approved,
                paid: true, onAllow: {}, onDeny: {})))
        case .checkoutExpired:
            return .view(AnyView(CheckoutApprovalCard(
                checkout: F.checkout(language, status: .expired), language: language, phase: .expired,
                onAllow: {}, onDeny: {})))
        case .purchaseOptions, .purchaseChosen:
            return .view(AnyView(PurchaseOptionsCard(detail: nil, language: language,
                preview: F.purchaseOptions(language, chosen: self == .purchaseChosen ? "a1b2c3d4-1" : nil),
                onChoose: { _ in })))
        case .purchaseSummary:
            return .markdown(PurchaseSummaryText.summary(F.checkout(language), card: "Visa ···4242", language: language))
        case .purchaseResult, .purchaseDeclined, .purchaseUnknown:
            var receipt = F.receipt(language)
            if self == .purchaseDeclined { receipt.outcome = "declined" }
            if self == .purchaseUnknown { receipt.outcome = "unknown" }
            return .markdown(PurchaseSummaryText.result(receipt, language: language))
        case .purchaseStopped:
            return .markdown(PurchaseSummaryText.stopped(F.errand(language, status: .stuck,
                reason: pick("The selected variant is out of stock.", "La variante elegida ya no tiene stock.")),
                language: language) ?? "")
        case .productSheet:
            return .view(AnyView(GalleryProductSheetButton(language: language)))
        case .errandWorking:
            return .view(AnyView(ErrandStack(
                errand: F.errand(language, status: .working), snapshot: .still(F.pageURL),
                onOpenBrowser: {}, onDecide: { _, _ in }, onAnswer: { _ in }, onConfirm: { _ in },
                demoCards: [SavedCard.demo(origin: nil)])))
        case .errandStuck:
            return .view(AnyView(ErrandProgressCard(
                errand: F.errand(language, status: .stuck,
                                 reason: pick("Out of stock in this size. Nothing was paid.",
                                              "Sin stock en esta talla. No se ha pagado nada.")))))
        case .receipt:
            return .view(AnyView(ErrandReceiptCard(receipt: F.receipt(language), language: language)))
        case .errandList:
            return .view(AnyView(VStack(spacing: 12) {
                ForEach(F.errandList(language)) { ErrandRow(errand: $0, showsLogo: false) }
            }))
        case .cardBadges:
            return .view(AnyView(HStack(spacing: 10) {
                ForEach(["Visa ···4242", "Mastercard ···5100", "Amex ···0005", "Tarjeta ···1234"], id: \.self) {
                    CardBrandBadge(label: $0)
                }
            }))
        case .liveBrowser:
            return .messages([F.reply("browser", "", pending: true, tools: [
                F.tool("b1", "browser_navigate", pick("# Open the creatine's page", "# Abrir la ficha de la creatina"),
                       done: false),
            ])])
        case .errandBrowser:
            return .view(AnyView(ErrandBrowserCard(errand: F.errand(language, status: .working),
                                                   snapshot: .still(F.pageURL), onOpen: {})))
        case .trace:
            var message = F.reply("trace", pick("Found it: 27.98 € at HSN, in stock.",
                                                "Encontrada: 27,98 € en HSN, en stock."), tools: [
                F.tool("s1", "web_search", "creatina creapure 500 g"),
                F.tool("s2", "browser_navigate", pick("# Open HSN", "# Abrir HSN")),
            ])
            message.reasoning = pick("The usual one is Creapure; HSN has it cheapest with free delivery.",
                                     "La de siempre es Creapure; HSN la tiene más barata y con envío gratis.")
            return .messages([message])
        case .plan:
            var message = F.reply("plan", "", pending: true)
            message.plan = TaskPlan(items: [
                .init(id: "1", content: pick("Find the product", "Encontrar el producto"), status: .completed, parent: nil),
                .init(id: "2", content: pick("Compare prices", "Comparar precios"), status: .inProgress, parent: nil),
                .init(id: "3", content: pick("Show you the options", "Enseñarte las opciones"), status: .pending, parent: nil),
            ], revision: 1)
            return .messages([message])
        case .routine:
            var message = F.reply("routine", pick("**Today**: dentist at 11:30 and dinner with Laura at 21:00.\n\nIt will rain after 18:00.",
                                                  "**Hoy**: dentista a las 11:30 y cena con Laura a las 21:00.\n\nLloverá a partir de las 18:00."))
            message.routineName = pick("Good morning", "Buenos días")
            return .messages([message])
        case .agentMessage:
            var message = F.reply("agent", pick("I found three deals on creatine this week.",
                                                "He encontrado tres ofertas de creatina esta semana."))
            message.fromAgent = "chollometro"
            return .messages([message])
        case .feedContext:
            guard let post = FeedSeed.posts().first else { return .markdown("") }
            var message = F.said("feed", "")
            message.feedContext = post
            return .messages([message])
        case .modelLimit:
            return .messages([F.reply("limit", "", error: pick("The model's allowance is spent.",
                                                                "Se ha agotado el uso del modelo."),
                                      errorLimit: ModelLimit(kind: .quota, retryAfterSeconds: 3600))])
        case .userMessage:
            return .messages([F.said("user", pick("Buy the Creapure creatine from HSN",
                                                  "Compra la creatina Creapure de HSN"))])
        case .reaction:
            return .messages([F.said("reaction", ReactionTurn(reaction: .yes, quote: pick("Shall I move dinner to Friday?",
                                                                                           "¿Paso la cena al viernes?"),
                                                              note: pick("added to the calendar", "añadido al calendario")).text)])
        case .attachment:
            let image = Attachment(id: "gallery-photo", name: "foto.png", mime: "image/png", kind: .image,
                                   data: F.photo.pngData() ?? Data())
            return .messages([F.said("attachment", pick("What plant is this?", "¿Qué planta es esta?"),
                                     attachments: [image])])
        case .streaming:
            return .messages([F.reply("streaming", pick("Looking at three shops, the cheapest so far is",
                                                        "Mirando tres tiendas, la más barata de momento es"),
                                      pending: true)])
        case .failed:
            return .messages([F.reply("failed", pick("I could not finish this.", "No he podido terminar esto."),
                                      error: pick("The connection to Hermes was lost.", "Se perdió la conexión con Hermes."))])
        }
    }
}

/// One sample, drawn the way a chat draws it.
struct GallerySampleView: View {
    let sample: GallerySample
    let language: ChatLanguage

    var body: some View {
        switch sample.content(language) {
        case let .markdown(text):
            RichMessageView(content: text)
        case let .messages(messages):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(messages) { MessageRow(message: $0) }
            }
        case let .view(view):
            view
        }
    }
}

/// The product sheet opens from a row, as it does from a product card.
private struct GalleryProductSheetButton: View {
    let language: ChatLanguage
    @Environment(\.colorScheme) private var scheme
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 14) {
                ProductThumb(url: GalleryFixtures.pageURL)
                    .frame(width: 60, height: 60)
                    .clipShape(.rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Creatina Excell 500 g (Creapure®)").font(.body.weight(.medium)).lineLimit(2)
                    Text("HSN · 27,98 €").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            PurchaseProductSheet(image: GalleryFixtures.pageURL, seller: "HSN", title: "Creatina Excell 500 g (Creapure®)",
                                 price: "27,98 €", oldPrice: "34,90 €", language: language,
                                 options: [language.pick("Unflavoured", "Sin sabor"), language.pick("Lemon", "Limón")]) {
                open = false
            }
        }
    }
}
