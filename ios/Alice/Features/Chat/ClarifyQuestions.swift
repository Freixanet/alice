import SwiftUI

/// Questions Hermes is waiting on, answered where they are shown.
///
/// Shared by Activity and by the chat that asked. A question from the chat
/// somebody is reading belongs in that chat, next to the conversation it is
/// about, not only in a list somewhere else.
struct ClarifyQuestionsView: View {
    @Environment(AppStore.self) private var store
    let event: AliceEvent
    /// Where it is drawn, for accessibility identifiers.
    var surface = "activity"
    var questionFont: Font = .footnote
    var size: ControlSize = .small

    @State private var answers: [String: String] = [:]
    @State private var selectedOptions: [String: Set<String>] = [:]
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(event.questions.enumerated()), id: \.offset) { offset, question in
                questionView(question, number: event.questions.count > 1 ? offset + 1 : nil)
            }
        }
    }

    @ViewBuilder
    private func questionView(_ question: AliceEvent.Question, number: Int?) -> some View {
        let key = question.id ?? "single"
        VStack(alignment: .leading, spacing: 8) {
            if let number {
                Text("Question \(number) of \(event.questions.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.text)
                .font(questionFont)
                .fixedSize(horizontal: false, vertical: true)

            if let answer = question.answer {
                Label("Answered: \(answer)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if !question.choices.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { options(question, key: key) }
                        VStack(alignment: .leading, spacing: 8) { options(question, key: key) }
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        question.allowsMultiple ? "Other answer (optional)" : "Your answer",
                        text: Binding(get: { answers[key] ?? "" }, set: { answers[key] = $0 }),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("\(surface).answer.field.\(key)")

                    Button("Send") {
                        Task { await sendTyped(question, key: key) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(size)
                    .disabled(sending || !hasAnswer(question, key: key))
                    .accessibilityIdentifier("\(surface).answer.send.\(key)")
                }
            }
        }
    }

    @ViewBuilder
    private func options(_ question: AliceEvent.Question, key: String) -> some View {
        ForEach(question.choices, id: \.self) { option in
            if question.allowsMultiple {
                Button {
                    var selected = selectedOptions[key] ?? []
                    if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
                    selectedOptions[key] = selected
                } label: {
                    Label(
                        option,
                        systemImage: (selectedOptions[key] ?? []).contains(option)
                            ? "checkmark.circle.fill" : "circle"
                    )
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .disabled(sending)
            } else {
                Button(option) {
                    Task { await send(option, questionID: question.id, key: key) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(size)
                .disabled(sending)
            }
        }
    }

    private func hasAnswer(_ question: AliceEvent.Question, key: String) -> Bool {
        let typed = (answers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return true }
        return question.allowsMultiple && !(selectedOptions[key] ?? []).isEmpty
    }

    private func sendTyped(_ question: AliceEvent.Question, key: String) async {
        let typed = (answers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let answer: String
        if question.allowsMultiple {
            var values = question.choices.filter { (selectedOptions[key] ?? []).contains($0) }
            if !typed.isEmpty { values.append(typed) }
            guard !values.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: values),
                  let encoded = String(data: data, encoding: .utf8)
            else { return }
            // Hermes explicitly accepts JSON arrays for multi-select replies;
            // this preserves labels containing commas unlike a comma join.
            answer = encoded
        } else {
            guard !typed.isEmpty else { return }
            answer = typed
        }
        await send(answer, questionID: question.id, key: key)
    }

    private func send(_ answer: String, questionID: String?, key: String) async {
        sending = true
        defer { sending = false }
        if await store.answerClarification(event, questionID: questionID, answer: answer) {
            answers[key] = nil
            selectedOptions[key] = nil
        }
    }
}

/// What the agent in this chat is waiting to be told, in the chat itself.
struct ChatQuestionsCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let conversationID: String

    var body: some View {
        let waiting = store.activity.filter {
            $0.isActionable && !$0.questions.isEmpty
                && $0.reference.conversationID == conversationID
        }
        ForEach(waiting) { event in
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    event.questions.count == 1
                        ? "Needs your answer" : "Needs \(event.questions.count) answers",
                    systemImage: "questionmark.bubble"
                )
                .font(.subheadline.weight(.semibold))

                ClarifyQuestionsView(
                    event: event, surface: "chat", questionFont: .body, size: .regular
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Palette.border(scheme), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.questions")
        }
    }
}
