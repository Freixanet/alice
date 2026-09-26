#if DEBUG
import Foundation

/// Synthetic, offline content for CI screenshots. Never reads a real account.
enum VisualReviewFixtures {
    static func notes(at date: Date) -> NotesSnapshot {
        NotesSnapshot(available: true, agent: "uitest-bot", notes: [
            Note(id: "visual-note-1", createdAt: date,
                 text: "Ideas para el viaje\nComparar trenes y preparar una lista corta de lugares para visitar.",
                 processed: true),
            Note(id: "visual-note-2", createdAt: date.addingTimeInterval(-86_400),
                 text: "Reunión del proyecto\nRevisar el prototipo, anotar dudas y decidir los próximos pasos.",
                 processed: true),
            Note(id: "visual-note-3", createdAt: date.addingTimeInterval(-172_800),
                 text: "Una idea para más adelante\nSimplificar lo que uso cada día antes de añadir algo nuevo.",
                 processed: true),
        ], supportsAttachments: true)
    }

    static func conversations(at date: Date) -> [Conversation] {
        [Conversation(
            id: "visual-home", title: "Preparar la semana", createdAt: date, updatedAt: date,
            messages: [
                Message(id: "visual-question", role: .user, content: "Ayúdame a organizar las ideas de esta semana.", createdAt: date),
                Message(id: "visual-answer", role: .assistant,
                        content: "Podemos empezar por tres cosas:\n\n1. Elegir una prioridad.\n2. Reservar tiempo para avanzar.\n3. Dejar margen para imprevistos.\n\n¿Qué necesitas tener listo primero?",
                        createdAt: date.addingTimeInterval(1)),
            ]
        ), Conversation(
            id: "visual-task", title: "Diseñar un agente de lectura", createdAt: date, updatedAt: date,
            messages: [Message(id: "visual-task-answer", role: .assistant,
                               content: "¿Qué temas quieres seguir y con qué frecuencia?", createdAt: date,
                               botName: "uitest-bot")],
            botName: "uitest-bot", agentTaskID: "visual-task"
        )]
    }
}
#endif
