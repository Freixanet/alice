import SwiftUI

/// The agent's other selves.
///
/// A bot in Hermes is not a separate kind of thing: it is a profile with its
/// own standing instructions, model, skills and sessions. What the desktop
/// client shows under Bot Mode is that, and so is this.
struct BotsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @State private var rows: [BotRow] = []
    @State private var failure: String?
    @State private var loading = false
    @State private var creating = false

    var body: some View {
        Group {
            if loading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                ContentUnavailableView(
                    "Bots", systemImage: "person.2", description: Text(failure)
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No bots", systemImage: "person.2",
                    description: Text("Every Hermes has at least a default profile.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New bot")
            }
        }
        .sheet(isPresented: $creating) {
            NewBotSheet { await load() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var list: some View {
        List(rows) { bot in
            NavigationLink {
                BotDetail(bot: bot, onChange: { Task { await load() } })
            } label: {
                HStack(spacing: 12) {
                    BotMarkView(mark: store.mark(for: bot.name), size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(bot.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if bot.active {
                                Text("Active")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        store.accent.primary(scheme).opacity(0.18),
                                        in: .capsule
                                    )
                            }
                            if bot.gatewayRunning {
                                Circle().fill(.green).frame(width: 6, height: 6)
                            }
                        }
                        if !bot.detail.isEmpty {
                            Text(bot.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text(subtitle(bot))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            .listRowBackground(Palette.card(scheme))
        }
    }

    private func subtitle(_ bot: BotRow) -> String {
        var parts: [String] = []
        if let model = bot.model { parts.append(model) }
        parts.append(bot.skills == 1 ? "1 skill" : "\(bot.skills) skills")
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { rows = try await store.bots(); failure = nil }
        catch { failure = describeBotError(error) }
    }
}

/// The mark pickers, shared by the detail screen and the create sheet.
struct MarkPicker: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var mark: BotMark

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(BotMark.colours.indices, id: \.self) { index in
                    Button { mark.colour = index } label: {
                        Circle()
                            .fill(BotMark.colours[index])
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle().strokeBorder(
                                    Color.primary,
                                    lineWidth: mark.colour == index ? 2 : 0
                                )
                                .padding(-3)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack(spacing: 0) {
                ForEach(BotMark.Silhouette.allCases, id: \.rawValue) { shape in
                    Button { mark.shape = shape.rawValue } label: {
                        BotMarkView(
                            mark: BotMark(colour: mark.colour, shape: shape.rawValue),
                            size: 24
                        )
                        .frame(maxWidth: .infinity)
                        .overlay {
                            Circle().strokeBorder(
                                Color.primary,
                                lineWidth: mark.shape == shape.rawValue ? 2 : 0
                            )
                            .frame(width: 34, height: 34)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// One bot: what it is told to be, what it runs on, and what it does on its
/// own schedule.
private struct BotDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bot: BotRow
    let onChange: () -> Void

    @State private var mark = BotMark(colour: 0, shape: 0)
    @State private var name = ""
    @State private var detail = ""
    @State private var routines: [JobRow] = []
    @State private var editingSoul = false
    @State private var busy = false
    @State private var failure: String?
    @State private var exported: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    BotMarkView(mark: mark, size: 84)
                    TextField("Name", text: $name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .onSubmit { commitName() }
                    Divider()
                    TextField("Title (optional)", text: $detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .onSubmit { commitDetail() }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .listRowBackground(Palette.card(scheme))
            }

            Section {
                MarkPicker(mark: $mark)
                    .listRowBackground(Palette.card(scheme))
                Button("Reset to default") {
                    mark = BotMark.derived(from: bot.name)
                }
                .listRowBackground(Palette.card(scheme))
            } header: {
                Text("Character")
            } footer: {
                Text("Kept on this phone. Hermes has no field for a colour.")
            }

            Section {
                Button { editingSoul = true } label: {
                    HStack {
                        Label("Instructions", systemImage: "doc.text")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.card(scheme))
            }

            Section("Routines") {
                if routines.isEmpty {
                    Text("No routines yet")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Palette.card(scheme))
                } else {
                    ForEach(routines) { routine in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(routine.enabled
                                          ? (routine.lastStatus == "error" ? .red : .green)
                                          : .secondary.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(routine.name).font(.subheadline).lineLimit(1)
                            }
                            if !routine.schedule.isEmpty {
                                Text(routine.schedule)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Palette.card(scheme))
                    }
                }
            }

            Section {
                LabeledContent("Model", value: bot.model ?? "—")
                    .listRowBackground(Palette.card(scheme))
                if let provider = bot.provider {
                    LabeledContent("Provider", value: provider)
                        .listRowBackground(Palette.card(scheme))
                }
                LabeledContent("Skills", value: "\(bot.skills)")
                    .listRowBackground(Palette.card(scheme))
            }

            Section {
                if !bot.active {
                    Button("Make this the active bot") {
                        act { try await store.activateBot(bot.name) }
                    }
                    .listRowBackground(Palette.card(scheme))
                }
            } footer: {
                if let failure {
                    Text(failure).foregroundStyle(.red)
                } else if let exported {
                    Text("Written to \(exported)").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(bot.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if busy {
                    ProgressView()
                } else {
                    Menu {
                        Button("Share as template", systemImage: "square.and.arrow.up") {
                            act { exported = try await store.exportBot(bot.name) }
                        }
                        Button("Copy name", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = bot.name
                        }
                        if !bot.isDefault {
                            Divider()
                            Button("Delete Bot", systemImage: "trash", role: .destructive) {
                                act { try await store.deleteBot(bot.name) } then: { dismiss() }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(isPresented: $editingSoul) {
            SoulEditor(bot: bot.name)
        }
        // Only a real change is worth storing. Assigning on appear would file
        // the derived mark the moment you opened a bot, freezing a colour
        // nobody picked.
        .onChange(of: mark) {
            guard mark != store.mark(for: bot.name) else { return }
            store.botMarks[bot.name] = mark
        }
        .task {
            mark = store.mark(for: bot.name)
            name = bot.displayName
            detail = bot.detail
            routines = (try? await store.routines(for: bot.name)) ?? []
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != bot.name, !trimmed.isEmpty else { return }
        act {
            try await store.renameBot(bot.name, to: trimmed)
            // The mark is filed under the name, so it moves with it.
            store.botMarks[trimmed] = store.mark(for: bot.name)
            store.botMarks[bot.name] = nil
        }
    }

    private func commitDetail() {
        guard detail != bot.detail else { return }
        act { try await store.setBotDescription(bot.name, detail) }
    }

    private func act(
        _ work: @escaping () async throws -> Void,
        then finish: @escaping () -> Void = {}
    ) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
                failure = nil
                onChange()
                finish()
            } catch {
                failure = describeBotError(error)
            }
        }
    }
}

/// The SOUL, given the screen. It is prose, often long, and editing it in a
/// form row means reading it through a letterbox.
private struct SoulEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let bot: String

    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    TextEditor(text: $text)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .scrollContentBackground(.hidden)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Palette.background(scheme))
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do {
                                    try await store.setSoul(bot, text)
                                    dismiss()
                                } catch {
                                    failure = describeBotError(error)
                                }
                            }
                        }
                    }
                }
            }
            .alert("Could not save", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .task {
                text = ((try? await store.soul(bot))?.text) ?? ""
                loaded = true
            }
        }
    }
}

private struct NewBotSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    let onCreated: () async -> Void

    @State private var name = ""
    @State private var detail = ""
    @State private var mark = BotMark(colour: 0, shape: 0)
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        BotMarkView(mark: mark, size: 84)
                        TextField("Name your bot", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Palette.card(scheme))
                }

                Section {
                    TextField("What it is for", text: $detail, axis: .vertical)
                        .lineLimit(2...4)
                        .listRowBackground(Palette.card(scheme))
                } footer: {
                    Text("A new profile with its own memory, sessions and standing instructions.")
                }

                Section("Character") {
                    MarkPicker(mark: $mark)
                        .listRowBackground(Palette.card(scheme))
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background(scheme))
            .navigationTitle("Create New Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Create") { create() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.createBot(name: trimmed, description: detail)
                store.botMarks[trimmed] = mark
                await onCreated()
                dismiss()
            } catch {
                failure = describeBotError(error)
            }
        }
    }
}

private func describeBotError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "The dashboard did not answer."
}
