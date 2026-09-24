import SwiftUI

/// Everything Alice is working toward for the person, and her plan for each:
/// what is under way, what is paused, what was reached. A goal is set by
/// telling Alice — in the chat or with "+" here — and she answers with a plan
/// she then keeps current as she works; the person can tick steps, add them,
/// pause or finish a goal here, or talk about it with her.
struct GoalsScreen: View {
    var onClose: () -> Void = {}

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var goals: [Goal] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var adding = false
    @State private var showingDone = false

    private var active: [Goal] { goals.filter { $0.status == .active } }
    private var paused: [Goal] { goals.filter { $0.status == .paused } }
    private var reached: [Goal] { goals.filter { $0.status == .done } }

    var body: some View {
        List {
            Text("Goals")
                .font(.aliceTitle(.largeTitle))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)

            if loaded && goals.isEmpty {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "scope")
                } description: {
                    Text("Tell Alice something you want to get done — a project, a change, a list that weighs on you — and she'll make a plan and work on it.")
                } actions: {
                    Button("Add a Goal") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }

            section("Under way", active)
            section("Paused", paused)

            if !reached.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showingDone) {
                        ForEach(reached) { goal in row(goal) }
                    } label: {
                        Text("Reached · \(reached.count)")
                            .font(.headline)
                    }
                }
                .listRowBackground(Palette.card(scheme))
            }

            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { Palette.background(scheme).ignoresSafeArea() }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { id in
            GoalDetailScreen(goalID: id, goals: $goals, onTalk: { talk($0, send: false) })
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("goals.back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a Goal")
                    .accessibilityIdentifier("goals.add")
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await load() } } }
        .sheet(isPresented: $adding) {
            NewGoalSheet { title, why in
                adding = false
                Task { await create(title: title, why: why) }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [Goal]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { goal in row(goal) }
            } header: {
                Text(title).font(.headline).foregroundStyle(.primary).textCase(nil)
            }
            .listRowBackground(Palette.card(scheme))
        }
    }

    private func row(_ goal: Goal) -> some View {
        NavigationLink(value: goal.id) {
            GoalRow(goal: goal)
        }
    }

    // MARK: Actions

    private func load() async {
        do {
            goals = try await store.goals()
            problem = nil
        } catch {
            problem = PlainWords.describe(error, doing: "load your goals")
        }
        loaded = true
    }

    /// A new goal is set here and planned by Alice in her own chat, where the
    /// plan arrives as her reply and she starts on it.
    private func create(title: String, why: String) async {
        do {
            if let goal = try await store.createGoal(title: title, why: why) {
                goals.insert(goal, at: 0)
            }
            var message = String(localized: "New goal: \(title).")
            if !why.isEmpty { message += " " + String(localized: "Why: \(why).") }
            message += " " + String(localized: "Make me a plan and get started.")
            talk(message, send: true)
        } catch {
            problem = PlainWords.describe(error, doing: "add this goal")
        }
    }

    /// To Alice's own chat: the words sent, or left in the composer to finish.
    private func talk(_ text: String, send: Bool) {
        onClose()
        store.openToday()
        store.draft = text
        if send { store.send() }
    }
}

/// A goal in the list: its title, how far along, and what is next.
private struct GoalRow: View {
    let goal: Goal

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(goal.status == .done ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if !goal.steps.isEmpty {
                    Text("\(goal.done) of \(goal.steps.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if !goal.steps.isEmpty {
                ProgressView(value: goal.progress)
                    .tint(goal.status == .done ? Palette.success(scheme) : store.accent.primary(scheme))
            }
            if goal.status != .done, let next = goal.next {
                Text("Next: \(next.text)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if goal.steps.isEmpty, goal.status == .active {
                Text("Alice is making the plan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let due = goal.dueDate, goal.status != .done {
                Text("By \(due.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.caption)
                    .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) ? Color.red : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One goal: why it matters, the plan to tick, what happened, and the way to
/// talk about it with Alice.
struct GoalDetailScreen: View {
    let goalID: String
    @Binding var goals: [Goal]
    let onTalk: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var newStep = ""
    @FocusState private var addingStep: Bool
    @State private var problem: String?
    @State private var confirmingDelete = false

    private var goal: Goal? { goals.first { $0.id == goalID } }

    var body: some View {
        if let goal {
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Text(goal.title)
                        .font(.aliceTitle(.title))
                        .fixedSize(horizontal: false, vertical: true)
                    if !goal.why.isEmpty {
                        Text(goal.why)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        if !goal.steps.isEmpty {
                            Label("\(goal.done) of \(goal.steps.count) steps", systemImage: "checklist")
                        }
                        if let due = goal.dueDate {
                            Label(due.formatted(.dateTime.day().month(.wide)), systemImage: "calendar")
                        }
                        if !goal.routines.isEmpty {
                            Label("\(goal.routines.count) routines", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    ForEach(goal.steps) { step in
                        stepRow(goal, step)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await change(GoalChange(stepID: step.id, removeStep: true)) }
                                }
                            }
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(store.accent.primary(scheme))
                        TextField("Add a step", text: $newStep)
                            .focused($addingStep)
                            .submitLabel(.done)
                            .onSubmit(addStep)
                    }
                } header: {
                    Text("Plan").font(.headline).foregroundStyle(.primary).textCase(nil)
                }
                .listRowBackground(Palette.card(scheme))

                if !goal.log.isEmpty {
                    Section {
                        ForEach(Array(goal.log.reversed().prefix(12).enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.subheadline)
                                Text("\(entry.byPerson ? String(localized: "You") : "Alice") · \(entry.at.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("What happened").font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                    .listRowBackground(Palette.card(scheme))
                }

                Section {
                    Button {
                        onTalk(String(localized: "About the goal “\(goal.title)”: "))
                    } label: {
                        Label("Talk about it with Alice", systemImage: "bubble.left.and.text.bubble.right")
                    }
                }
                .listRowBackground(Palette.card(scheme))

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(Palette.danger(scheme))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { Palette.background(scheme).ignoresSafeArea() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if goal.status == .active {
                            Button { Task { await change(GoalChange(status: .paused)) } } label: {
                                Label("Pause", systemImage: "pause")
                            }
                        } else {
                            Button { Task { await change(GoalChange(status: .active)) } } label: {
                                Label("Resume", systemImage: "play")
                            }
                        }
                        if goal.status != .done {
                            Button { Task { await change(GoalChange(status: .done)) } } label: {
                                Label("Mark as Reached", systemImage: "checkmark.seal")
                            }
                        }
                        Divider()
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete Goal", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Goal options")
                }
            }
            .confirmationDialog("Delete this goal?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Goal", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Its plan and history go. Routines working on it keep running until you stop them.")
            }
        } else {
            ContentUnavailableView("Goal not found", systemImage: "scope")
        }
    }

    private func stepRow(_ goal: Goal, _ step: Goal.Step) -> some View {
        let done = step.status == .done
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                Task { await change(GoalChange(stepID: step.id, stepStatus: done ? .todo : .done)) }
            } label: {
                ZStack {
                    Circle().strokeBorder(done ? store.accent.primary(scheme) : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if done { Circle().fill(store.accent.primary(scheme)).padding(4) }
                }
                .frame(width: 22, height: 22)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityLabel(done ? "Done" : "Mark as done")
            .sensoryFeedback(.success, trigger: done) { _, now in now }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.text)
                    .foregroundStyle(done ? .secondary : .primary)
                if step.status == .doing {
                    Text("Alice is on it").font(.caption).foregroundStyle(store.accent.primary(scheme))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func addStep() {
        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newStep = ""
        Task {
            await change(GoalChange(addStep: text))
            addingStep = true
        }
    }

    private func change(_ body: GoalChange) async {
        do {
            if let updated = try await store.changeGoal(goalID, body),
               let index = goals.firstIndex(where: { $0.id == goalID }) {
                withAnimation(.snappy) { goals[index] = updated }
            }
            problem = nil
        } catch {
            problem = PlainWords.describe(error, doing: "change this goal")
        }
    }

    private func delete() async {
        do {
            try await store.deleteGoal(goalID)
            goals.removeAll { $0.id == goalID }
            dismiss()
        } catch {
            problem = PlainWords.describe(error, doing: "delete this goal")
        }
    }
}

/// A new goal: what, and optionally why. Alice makes the plan.
private struct NewGoalSheet: View {
    let onAdd: (String, String) -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var why = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to get done?", text: $title, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...3)
                    TextField("Why it matters (optional)", text: $why, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("Alice will make a plan, start on it and keep it up to date here.")
                }
            }
            .aliceFormPaper(scheme)
            .navigationTitle("New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(title.trimmingCharacters(in: .whitespacesAndNewlines),
                              why.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }
}
