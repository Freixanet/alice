import SwiftUI

/// What Alice learned after a reply: in plain words first, the lesson itself on request.
///
/// The plain words come from the plugin (`skill_keeper.py` asks the model once, when the lesson is
/// kept). A lesson kept before that has none, and then her reply, which said it, is shown instead.
struct LessonSheet: View {
    let lessons: [AgentAction]
    let reply: String
    @Environment(\.dismiss) private var dismiss

    private var language: ChatLanguage { ChatLanguage.of(reply) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(lessons) { lesson in
                    Section {
                        Text(lesson.summary ?? reply)
                        if let text = lesson.text {
                            DisclosureGroup(language.pick("Details", "Ver detalles")) {
                                Text(Self.markdown(text))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .navigationTitle(language.pick("What I learned", "Lo que he aprendido"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.pick("Done", "Listo")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
