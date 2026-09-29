import SwiftUI

/// Questions Hermes is waiting on, answered in the chat that asked.
///
/// One at a time, with a quiet pager to look back or ahead: a batch shown
/// whole reads as a form. Picking a choice answers and moves on; anything else
/// goes in the field underneath, whose button skips the question while it is
/// empty and sends once there is something to send.
///
/// Hermes keeps each answer of a batch open to change until the last one is
/// in, so an answered question can be picked again. Picking on the last open
/// question sends them all.
struct ClarifyQuestionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let event: AliceEvent
    /// Sits at the top left, level with the pager.
    let title: String
    /// Where it is drawn, for accessibility identifiers.
    var surface = "chat"

    @State private var shown: Int?
    @State private var typed: [String: String] = [:]
    @State private var selected: [String: Set<String>] = [:]
    @State private var sending = false
    @FocusState private var fieldFocused: Bool

    private static let radius: CGFloat = 14

    private var questions: [AliceEvent.Question] { event.questions }

    /// The first question still waiting.
    private var firstOpen: Int {
        questions.firstIndex { $0.answer == nil } ?? max(0, questions.count - 1)
    }

    private var index: Int {
        min(max(shown ?? firstOpen, 0), max(0, questions.count - 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label(title, systemImage: "questionmark.bubble")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if questions.count > 1 { pager }
            }

            if questions.indices.contains(index) {
                questionView(questions[index])
                    .id(questions[index].id ?? "single")
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: index)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button("Previous Question", systemImage: "chevron.left") {
                shown = index - 1
            }
            .disabled(index == 0)
            Text("\(index + 1) of \(questions.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(minWidth: 44)
            Button("Next Question", systemImage: "chevron.right") {
                shown = index + 1
            }
            .disabled(index >= questions.count - 1)
        }
        .labelStyle(.iconOnly)
        .font(.footnote.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(surface).questions.pager")
    }

    // MARK: - One question

    @ViewBuilder
    private func questionView(_ question: AliceEvent.Question) -> some View {
        let key = question.id ?? "single"
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text)
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if !question.choices.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { number, option in
                        choiceRow(option, number: number + 1, question: question, key: key)
                    }
                }
                if question.allowsMultiple {
                    Text("Select all that apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let given = question.answer {
                answeredNote(given, question: question)
            }
            answerField(question, key: key)
        }
        .disabled(sending)
    }

    /// What this question's rows show as picked: a choice being made, else the
    /// answer Hermes holds.
    private func picked(_ question: AliceEvent.Question, key: String) -> Set<String> {
        if let choosing = selected[key] { return choosing }
        return question.answer.map { Set(Self.values($0)) } ?? []
    }

    /// A written or skipped answer, which the rows cannot show.
    @ViewBuilder
    private func answeredNote(_ answer: String, question: AliceEvent.Question) -> some View {
        let chosen = Set(Self.values(answer))
        let isChoice = !answer.isEmpty && chosen.isSubset(of: Set(question.choices))
        if answer.isEmpty {
            Label("Skipped", systemImage: "arrow.uturn.forward")
                .font(.footnote).foregroundStyle(.secondary)
        } else if !isChoice {
            Label(Self.readable(answer), systemImage: "checkmark")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What a row reads. Hermes marks the first choice "(Recommended)" —
    /// which is advice on a question with one answer, and noise on one where
    /// every row can be ticked: nothing is recommended over the others when
    /// the reader is picking several. The value sent back keeps the label.
    static func label(_ option: String, multiple: Bool) -> String {
        guard multiple else { return option }
        let mark = "(Recommended)"
        guard option.hasSuffix(mark) else { return option }
        return String(option.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
    }

    private func choiceRow(
        _ option: String, number: Int, question: AliceEvent.Question, key: String
    ) -> some View {
        let isSelected = picked(question, key: key).contains(option)
        let tint = store.accent.primary(scheme)
        return Button {
            choose(option, question: question, key: key)
        } label: {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Palette.background(scheme)),
                        in: .rect(cornerRadius: 8)
                    )
                Text(Self.label(option, multiple: question.allowsMultiple))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(Palette.background(scheme), in: .rect(cornerRadius: Self.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius)
                    .strokeBorder(isSelected ? tint : Palette.border(scheme),
                                  lineWidth: isSelected ? 1.5 : 0.5)
            }
            .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isSelected)
        .accessibilityLabel("\(number). \(option)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(surface).answer.choice.\(key).\(number)")
    }

    private func answerField(_ question: AliceEvent.Question, key: String) -> some View {
        let text = Binding(
            get: { typed[key] ?? "" },
            set: { typed[key] = $0 }
        )
        let ready = hasAnswer(question, key: key)
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Something else", text: text, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .accessibilityIdentifier("\(surface).answer.field.\(key)")

            Group {
                if ready {
                    Button {
                        Task { await submit(question, key: key) }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(store.accent.control(scheme), in: .rect(cornerRadius: 10))
                    }
                    .accessibilityLabel("Send answer")
                    .accessibilityIdentifier("\(surface).answer.send.\(key)")
                } else if question.answer == nil {
                    Button {
                        Task { await send("", question: question, key: key, skip: true) }
                    } label: {
                        Text("Skip")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(Palette.background(scheme), in: .rect(cornerRadius: 10))
                    }
                    .accessibilityIdentifier("\(surface).answer.skip.\(key)")
                }
            }
            .buttonStyle(.plain)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.2), value: ready)
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: Self.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius)
                .strokeBorder(
                    fieldFocused ? store.accent.primary(scheme).opacity(0.6) : Palette.border(scheme),
                    lineWidth: fieldFocused ? 1.2 : 0.5
                )
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.15), value: fieldFocused)
    }

    // MARK: - Answering

    /// A single choice is the answer: sent at once, and on to the next.
    /// Several can be picked where the question allows, then sent together.
    private func choose(_ option: String, question: AliceEvent.Question, key: String) {
        if question.allowsMultiple {
            var choosing = picked(question, key: key)
            if choosing.contains(option) { choosing.remove(option) } else { choosing.insert(option) }
            withAnimation(.snappy(duration: 0.2)) { selected[key] = choosing }
            return
        }
        withAnimation(.snappy(duration: 0.2)) { selected[key] = [option] }
        typed[key] = nil
        // A pick is the answer, the last question's too: pressing Send in the
        // field after choosing a row asked for a second decision nobody had.
        if question.answer == option {
            selected[key] = nil
            advance()
            return
        }
        Task { await send(option, question: question, key: key, skip: false) }
    }

    private func hasAnswer(_ question: AliceEvent.Question, key: String) -> Bool {
        let written = (typed[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return true }
        guard let choosing = selected[key], !choosing.isEmpty else { return false }
        // A pick equal to what Hermes holds is nothing new to send.
        return Set(question.answer.map(Self.values) ?? []) != choosing || question.answer == nil
    }

    /// On to the first question still waiting, or the next one along.
    private func advance() {
        if let open = questions.firstIndex(where: { $0.answer == nil }) {
            shown = open
        } else {
            shown = min(index + 1, questions.count - 1)
        }
    }

    private func submit(_ question: AliceEvent.Question, key: String) async {
        let written = (typed[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if question.allowsMultiple {
            var values = question.choices.filter { (selected[key] ?? []).contains($0) }
            if !written.isEmpty { values.append(written) }
            guard !values.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: values),
                  let encoded = String(data: data, encoding: .utf8)
            else { return }
            // Hermes explicitly accepts JSON arrays for multi-select replies;
            // this preserves labels containing commas unlike a comma join.
            await send(encoded, question: question, key: key, skip: false)
        } else if !written.isEmpty {
            await send(written, question: question, key: key, skip: false)
        } else if let choice = selected[key]?.first {
            await send(choice, question: question, key: key, skip: false)
        }
    }

    private func send(
        _ answer: String, question: AliceEvent.Question, key: String, skip: Bool
    ) async {
        sending = true
        defer { sending = false }
        if await store.answerClarification(
            event, questionID: question.id, answer: answer, skip: skip
        ) {
            typed[key] = nil
            selected[key] = nil
            fieldFocused = false
            shown = nil
        }
    }

    // MARK: - Reading answers

    /// A multi-select answer travels as a JSON array.
    nonisolated static func values(_ answer: String) -> [String] {
        guard let data = answer.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [answer] }
        return values
    }

    nonisolated static func readable(_ answer: String) -> String {
        values(answer).joined(separator: ", ")
    }
}

/// What the agent in this chat is waiting to be told, in the chat itself.
struct ChatQuestionsCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let conversationID: String

    var body: some View {
        let waiting = store.pendingQuestions(in: conversationID)
        ForEach(waiting) { event in
            ClarifyQuestionsView(
                event: event,
                title: event.questions.count == 1
                    ? "Needs your answer" : "Needs \(event.questions.count) answers"
            )
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Palette.border(scheme), lineWidth: 0.5)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.questions")
        }
    }
}

// MARK: - Questions that do not stop the work (`ask_person`)

/// What an agent asked with the Alice plugin's `ask_person` tool. Unlike
/// clarify, the tool returns at once and the agent keeps working: the card is
/// drawn from the tool call, and the answer goes back as the person's own
/// message, `[respuesta:<id>] <value>` per line, which Hermes folds into the
/// running turn.
struct AskPerson: Hashable, Sendable {
    struct Question: Hashable, Sendable, Identifiable {
        let id: String
        let question: String
        let choices: [String]
        let multi: Bool
        /// A personal or delivery detail (`name`, `id`, `address`…): typed.
        let field: String?
    }

    static let toolName = "ask_person"

    let title: String?
    let questions: [Question]

    static func isTool(_ name: String) -> Bool { name == toolName }

    /// The tool call's arguments, kept as the step's detail (`AppStore.toolDetail`).
    static func parse(_ detail: String?) -> AskPerson? {
        guard let data = detail?.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = args["questions"] as? [[String: Any]]
        else { return nil }
        let questions = raw.compactMap { item -> Question? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let text = item["question"] as? String, !text.isEmpty
            else { return nil }
            let field = (item["field"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Question(id: id, question: text,
                            choices: (item["choices"] as? [String]) ?? [],
                            multi: (item["multi"] as? Bool) ?? false, field: field)
        }
        guard !questions.isEmpty else { return nil }
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AskPerson(title: title, questions: questions)
    }

    static func answer(_ values: [(id: String, value: String)]) -> String {
        values.map { "[respuesta:\($0.id)] \($0.value)" }.joined(separator: "\n")
    }

    /// A sent answer as the person reads it: the values, without the ids.
    static func display(_ text: String) -> String {
        guard text.contains("[respuesta:") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/^\[respuesta:[A-Za-z0-9_.-]{1,40}\]\s?/, with: "") }
            .joined(separator: "\n")
    }

    /// Asked again later with the same ids — once the agent knew the real options — so this
    /// card gives way to the newer one instead of both waiting for an answer.
    static func superseded(_ ask: AskPerson, callID: String, in messages: [Message]) -> Bool {
        let ids = Set(ask.questions.map(\.id))
        var seen = false
        for message in messages where message.role == .assistant {
            for call in message.tools where isTool(call.name) {
                if seen, let later = parse(call.detail), !ids.isDisjoint(with: later.questions.map(\.id)) {
                    return true
                }
                if call.id == callID { seen = true }
            }
        }
        return false
    }

    static func answered(_ questionID: String, in messages: [Message]) -> Bool {
        messages.contains { $0.role == .user && $0.content.contains("[respuesta:\(questionID)]") }
    }
}

/// The card for an `ask_person` call, inside the reply that asked it. The agent
/// is still working meanwhile; answering sends the values as one message.
struct AskPersonCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let ask: AskPerson

    @State private var typed: [String: String] = [:]
    @State private var picked: [String: Set<String>] = [:]
    @State private var sent = false

    private var answered: Bool {
        sent || AskPerson.answered(ask.questions[0].id, in: store.shownConversation?.messages ?? [])
    }

    private func value(_ question: AskPerson.Question) -> String {
        let text = (typed[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return question.choices.filter { (picked[question.id] ?? []).contains($0) }.joined(separator: ", ")
    }

    private var complete: Bool { ask.questions.allSatisfy { !value($0).isEmpty } }

    var body: some View {
        let tint = store.accent.primary(scheme)
        VStack(alignment: .leading, spacing: 14) {
            if let title = ask.title {
                Text(title).font(.headline)
            }
            if answered {
                Label("Answered", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ask.questions) { question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.question).font(.subheadline.weight(.semibold))
                        ForEach(question.choices, id: \.self) { choice in
                            let on = (picked[question.id] ?? []).contains(choice)
                            Button {
                                var set = question.multi ? (picked[question.id] ?? []) : []
                                if on { set.remove(choice) } else { set.insert(choice) }
                                picked[question.id] = set
                                typed[question.id] = nil
                                // One question, one tap: answered at once.
                                if ask.questions.count == 1, !question.multi, !on { submit() }
                            } label: {
                                HStack {
                                    Text(choice).foregroundStyle(.primary)
                                    Spacer()
                                    if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(tint) }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Palette.background(scheme), in: .rect(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(on ? tint : Palette.border(scheme),
                                                      style: StrokeStyle(lineWidth: 1, dash: on ? [] : [4, 3]))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        TextField(question.choices.isEmpty ? question.question : "Something else",
                                  text: Binding(get: { typed[question.id] ?? "" },
                                                set: { typed[question.id] = $0 }))
                            .textFieldStyle(.plain)
                            .keyboardType(Self.keyboard(question.field))
                            .textContentType(Self.content(question.field))
                            .autocorrectionDisabled(question.field != nil)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Palette.background(scheme), in: .rect(cornerRadius: 12))
                    }
                }
                if ask.questions.count > 1 || ask.questions.contains(where: { $0.choices.isEmpty || $0.multi }) {
                    Button("Send", action: submit)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!complete)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20).stroke(Palette.border(scheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.askPerson")
    }

    private func submit() {
        guard complete, !sent else { return }
        sent = true
        store.sendQuickReply(AskPerson.answer(ask.questions.map { ($0.id, value($0)) }))
    }

    private static func keyboard(_ field: String?) -> UIKeyboardType {
        switch field {
        case "email": .emailAddress
        case "phone": .phonePad
        case "postcode": .numberPad
        default: .default
        }
    }

    private static func content(_ field: String?) -> UITextContentType? {
        switch field {
        case "name": .givenName
        case "surname": .familyName
        case "address": .streetAddressLine1
        case "postcode": .postalCode
        case "city": .addressCity
        case "province": .addressState
        case "phone": .telephoneNumber
        case "email": .emailAddress
        default: nil
        }
    }
}
