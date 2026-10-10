import Foundation

/// Local examples rendered by TaskResultBlocks, without a Task or a Hermes connection.
enum TaskBlockGallery: String, CaseIterable {
    case text, table, checklist, draft, event, linkCard = "link_card"

    func title(spanish: Bool) -> String {
        switch self {
        case .text: spanish ? "Texto de tarea" : "Task text"
        case .table: spanish ? "Tabla de tarea" : "Task table"
        case .checklist: spanish ? "Lista de comprobación" : "Task checklist"
        case .draft: spanish ? "Borrador de tarea" : "Task draft"
        case .event: spanish ? "Evento de tarea" : "Task event"
        case .linkCard: spanish ? "Tarjeta de enlace" : "Task link card"
        }
    }

    func block(spanish: Bool) -> ReviewTask.Block {
        func pick(_ english: String, _ translated: String) -> String { spanish ? translated : english }
        var text: String?, title: String?, channel: String?, subject: String?, body: String?
        var startIso: String?, location: String?, url: String?
        var columns: [String]?, rows: [[String]]?, to: [String]?
        var items: [ReviewTask.Block.Item]?
        switch self {
        case .text:
            text = pick("Thanks for your help. This note stays as a local draft.",
                        "Gracias por tu ayuda. Esta nota queda como borrador local.")
        case .table:
            columns = [pick("Option", "Opción"), pick("Price", "Precio"), pick("Delivery", "Entrega")]
            rows = [[pick("Standard", "Estándar"), "12 €", pick("3 days", "3 días")],
                    [pick("Express", "Exprés"), "18 €", pick("1 day", "1 día")]]
        case .checklist:
            items = [.init(text: pick("Recipient checked", "Destinatario comprobado"), done: true),
                     .init(text: pick("Amount checked", "Importe comprobado"), done: true),
                     .init(text: pick("Awaiting your review", "Pendiente de tu revisión"), done: false)]
        case .draft:
            channel = "email"
            to = ["example@example.com"]
            subject = pick("Appointment confirmation", "Confirmación de la cita")
            body = pick("Hello, I confirm the appointment for Friday. Thank you.\n\nExample only: this message has not been sent.",
                        "Hola, confirmo la cita del viernes. Gracias.\n\nSolo es un ejemplo: este mensaje no se ha enviado.")
        case .event:
            title = pick("Example meeting", "Reunión de ejemplo")
            startIso = "2026-10-16T10:00:00+02:00"
            location = pick("Online · example only", "Online · solo un ejemplo")
        case .linkCard:
            title = pick("Example reference", "Referencia de ejemplo")
            url = "https://example.com"
        }
        return .init(type: rawValue, text: text, title: title, columns: columns, rows: rows,
                     items: items, channel: channel, to: to, subject: subject, body: body,
                     startIso: startIso, location: location, url: url)
    }
}
