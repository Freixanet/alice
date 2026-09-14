import PhotosUI
import SwiftUI

/// The composer every model client has converged on: the text on its own line,
/// and the controls underneath — attach and model on the left, send on the
/// right.
///
/// It sits on Liquid Glass so the transcript stays visible behind it, and the
/// field and the button share one `GlassEffectContainer` so they read as a
/// single surface rather than two stacked shapes.
struct Composer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    var focused: FocusState<Bool>.Binding
    var placeholder: String = "Talk to Alice…"
    var keyboardShown = false
    @Namespace private var glass
    @State private var showModels = false
    @State private var dictation = Dictation()
    /// Set by swiping the command list away. Cleared on the next keystroke,
    /// so dismissing it is about this moment, not about the whole draft.
    @State private var commandsDismissed = false
    @State private var commandsHeight: CGFloat = 180
    @State private var botMentionsHeight: CGFloat = 160
    @State private var fetchedBotsForMention = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    /// Counts taps rather than watching `listening`, so the tap is felt even
    /// when dictation fails to start — which is exactly when the reader most
    /// needs to know the button registered.
    @State private var micTaps = 0
    @State private var pendingListen: Bool?

    /// One height for every control on the bottom row, so the send button and
    /// the model chip line up instead of each taking the size its own padding
    /// happens to produce.
    private let controlHeight: CGFloat = 34

    var body: some View {
        // The list grows upward out of a composer pinned to the bottom, so
        // offering it never moves the field out from under the caret.
        VStack(spacing: 8) {
            if store.activeIsRecoveredHistory {
                // Read-only, and it says so. Typing into recovered history
                // would either resume a simulated session on the wrong profile
                // or be redirected into the bot's real one — two different
                // agents' conversations spliced into one apparent history.
                Text("Recovered history")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                if !commands.isEmpty { commandList }
                else if !matchingBots.isEmpty { botMentionList }
                if isBotChat { botComposer }
                else { aliceComposer }
            }
        }
        .padding(.horizontal, isBotChat ? 20 : 18)
        // Bot chats sit flush with the bottom safe area. Keep the larger
        // keyboard gap requested for typing, and leave Alice's resting
        // position unchanged.
        .padding(.bottom, keyboardShown ? 10 : (isBotChat ? 0 : 6))
        // Flicking the composer down puts the keyboard away, which is quicker
        // than reaching for the transcript to tap it.
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 40 { focused.wrappedValue = false }
                }
        )
        .sheet(isPresented: $showModels) { ModelPicker() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { store.draftAttachments.append($0) }
                .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $showPhotos, selection: $photos,
            maxSelectionCount: 4, matching: .images
        )
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            photos = []
            Task {
                for item in picked {
                    if let attachment = await AttachmentLoader.image(from: item) {
                        store.draftAttachments.append(attachment)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                if let attachment = AttachmentLoader.file(at: url) {
                    store.draftAttachments.append(attachment)
                }
            }
        }
        .onChange(of: store.draft) { commandsDismissed = false }
        .animation(.snappy(duration: 0.2), value: commands.isEmpty && matchingBots.isEmpty)
        .task(id: store.dashboardReady) {
            _ = try? await store.bots()
        }
        // Once, when the mention list first opens — not on every keystroke.
        // Keyed on the draft, this fired a dashboard request per character
        // typed, and since a failed fetch leaves the cache empty it never
        // stopped firing.
        .onChange(of: botMentionQuery != nil) { _, mentioning in
            guard mentioning, store.cachedBots.isEmpty, !fetchedBotsForMention
            else { return }
            fetchedBotsForMention = true
            Task { _ = try? await store.bots() }
        }
    }

    private var commands: [SlashCommand] {
        commandsDismissed ? [] : Slash.matches(store.draft)
    }

    private var isBotChat: Bool {
        store.activeBotProfileForModelSelection != nil
    }

    private var botMentionQuery: String? {
        guard let atIndex = store.draft.lastIndex(of: "@") else { return nil }
        if atIndex > store.draft.startIndex {
            let prev = store.draft[store.draft.index(before: atIndex)]
            guard prev.isWhitespace || prev.isNewline else { return nil }
        }
        let afterAt = store.draft[atIndex...]
        if afterAt.contains("\n") { return nil }
        let word = String(afterAt)
        if word.dropFirst().contains(" ") { return nil }
        return String(word.dropFirst()).lowercased()
    }

    private var matchingBots: [BotRow] {
        guard let query = botMentionQuery, !commandsDismissed else { return [] }
        let all: [BotRow]
        if !store.cachedBots.isEmpty {
            all = store.cachedBots
        } else {
            all = store.knownBotNames.map { name in
                BotRow(
                    name: name,
                    displayName: store.botCurrentName(for: name),
                    detail: "",
                    model: nil,
                    provider: nil,
                    skills: 0,
                    isDefault: false,
                    gatewayRunning: false,
                    active: false
                )
            }
        }
        if query.isEmpty { return all }
        return all.filter {
            $0.name.lowercased().contains(query) ||
            $0.displayName.lowercased().contains(query) ||
            store.botCurrentName(for: $0).lowercased().contains(query)
        }
    }

    private var botMentionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matchingBots) { bot in
                    Button {
                        if let atIndex = store.draft.lastIndex(of: "@") {
                            let prefix = store.draft[..<atIndex]
                            let botName = store.botCurrentName(for: bot)
                            store.draft = ""
                            DispatchQueue.main.async {
                                store.draft = prefix + "@" + botName + " "
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            BotMarkView(mark: store.mark(for: bot.name), size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text("@\(store.botCurrentName(for: bot))")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    let currentName = store.botCurrentName(for: bot)
                                    if currentName.lowercased() != bot.name.lowercased() {
                                        Text(bot.name)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                let liveDetail = store.cachedBots.first(where: { $0.name == bot.name })?.detail ?? bot.detail
                                if !liveDetail.isEmpty {
                                    Text(liveDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                if $0 > 0 { botMentionsHeight = $0 }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(botMentionsHeight, 260))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 40 { commandsDismissed = true }
                }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var commandList: some View {
        ScrollView {
            // Not lazy: fourteen rows at most, and a lazy stack cannot report
            // the height this panel is sized from until it has been laid out.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { item in
                    Button {
                        // The trailing space is the point: it closes the list
                        // and leaves the caret where the argument goes.
                        //
                        // Replacing the draft in one assignment races the
                        // field's own pending edit — tapping /memory over a
                        // typed "/mem" produced "/mem ory". Emptying it first
                        // and writing on the next turn of the run loop gives
                        // the field a change it cannot merge into the old text.
                        store.draft = ""
                        DispatchQueue.main.async { store.draft = item.cmd + " " }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.cmd)
                                .font(.subheadline.monospaced())
                            Text(item.hint)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                commandsHeight = $0
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Fits its rows, up to a ceiling: tall enough to be worth scrolling
        // for a narrow query, short enough that "/" alone does not bury the
        // conversation behind it.
        .frame(height: min(commandsHeight, 280))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.translation.height > 40 { commandsDismissed = true }
                }
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var aliceComposer: some View {
        @Bindable var store = store

        return GlassEffectContainer(spacing: 14) {
            VStack(spacing: 18) {
                if !store.draftAttachments.isEmpty {
                    AttachmentChips(attachments: store.draftAttachments) { attachment in
                        store.draftAttachments.removeAll { $0.id == attachment.id }
                    }
                }

                TextField(placeholder, text: $store.draft, axis: .vertical)
                    .lineLimit(1...7)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(focused)
                    .padding(.horizontal, 4)
                    // The field only claims the height of its own text, so a
                    // tap anywhere on the upper half of the composer used to
                    // land on inert glass. Give it a real target.
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                    // Sitting flush against the top of its own box read as
                    // crowded against the glass above it.
                    .padding(.top, 4)
                    .contentShape(.rect)
                    .onTapGesture { focused.wrappedValue = true }

                HStack(spacing: 8) {
                    attachButton
                    modelChip
                    Spacer(minLength: 4)
                    micButton
                    actionButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .glassEffectID("composer", in: glass)
            // The composer keeps its own presses. Glass is not a hit target,
            // so a press on its padding — or on Send while it is disabled —
            // fell through to the page behind, whose tap puts the keyboard
            // away. Its controls still take precedence over this.
            .contentShape(.rect(cornerRadius: 26))
            .onTapGesture {}
        }
    }

    /// Bot chats deliberately have a smaller, single-line composer. Their
    /// model belongs in profile settings, while attachment is a peer of the
    /// 44pt back button above rather than a control buried in the field.
    private var botComposer: some View {
        @Bindable var store = store

        return GlassEffectContainer(spacing: 10) {
            VStack(spacing: 8) {
                if !store.draftAttachments.isEmpty {
                    AttachmentChips(attachments: store.draftAttachments) { attachment in
                        store.draftAttachments.removeAll { $0.id == attachment.id }
                    }
                }

                HStack(spacing: 10) {
                    botAttachButton

                    HStack(spacing: 6) {
                        TextField(placeholder, text: $store.draft)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .focused(focused)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(.rect)
                            .onTapGesture { focused.wrappedValue = true }

                        botVoiceOrSendButton
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 5)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("composer", in: glass)
                    .contentShape(.capsule)
                    .onTapGesture {}
                }
            }
        }
    }

    private var botAttachButton: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button {
                showPhotos = true
            } label: {
                Label("Photos", systemImage: "photo")
            }
            Button {
                showFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .menuOrder(.fixed)
        .accessibilityLabel("Attach")
    }

    /// One trailing control: dictation while the field is empty, Send as soon
    /// as there is content, and Stop while a reply is streaming.
    @ViewBuilder
    private var botVoiceOrSendButton: some View {
        let listening = pendingListen ?? dictation.isListening
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.draftAttachments.isEmpty
        let stopping = store.isSending && !hasDraft && !listening

        Button {
            if listening {
                toggleDictation(listening: true)
            } else if stopping {
                store.stop()
            } else if hasDraft {
                store.send()
            } else {
                toggleDictation(listening: false)
            }
        } label: {
            Image(
                systemName: listening
                    ? "waveform" : (stopping ? "stop.fill" : (hasDraft ? "arrow.up" : "mic"))
            )
            .font(.system(size: 16, weight: hasDraft ? .semibold : .medium))
            .frame(width: controlHeight, height: controlHeight)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor, isActive: listening)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            listening || stopping || hasDraft
                ? AnyShapeStyle(store.accent.primary(scheme)) : AnyShapeStyle(.secondary)
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: micTaps)
        .accessibilityLabel(
            listening ? "Stop dictating" : (stopping ? "Stop" : (hasDraft ? "Send" : "Dictate"))
        )
        .accessibilityIdentifier("composer.action")
        .onChange(of: dictation.isListening) { _, _ in pendingListen = nil }
    }

    private func toggleDictation(listening: Bool) {
        micTaps += 1
        pendingListen = !listening
        let draft = store.draft
        Task {
            dictation.prime(with: draft)
            dictation.toggle { store.draft = $0 }
        }
    }

    /// Photos or files, both folded into the next message.
    ///
    /// It was a disabled placeholder holding the layout open for work that had
    /// not been done; a control that cannot be pressed is worse than no
    /// control, so it now does the thing it has always looked like it does.
    private var attachButton: some View {
        Menu {
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button {
                showPhotos = true
            } label: {
                Label("Photos", systemImage: "photo")
            }
            Button {
                showFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                // Full strength: at secondary it read as the disabled control
                // it used to be, which is the opposite of what it now is.
                .foregroundStyle(.primary)
                .frame(width: controlHeight, height: controlHeight)
                .background(Palette.muted(scheme).opacity(0.7), in: .circle)
        }
        .buttonStyle(.plain)
        // A menu opening upward is reordered by default, on the reasoning that
        // the likeliest choice belongs nearest the thumb. Here the three are
        // meant to be read in the order they are written.
        .menuOrder(.fixed)
        .accessibilityLabel("Attach")
    }

    /// The model belongs next to the message it will answer, not buried in a
    /// settings screen — it is the single choice that most changes the reply.
    private var modelChip: some View {
        Button {
            showModels = true
        } label: {
            Text(currentModel)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: controlHeight)
            .background(Palette.muted(scheme).opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!store.isConnected)
        .accessibilityLabel("Model: \(currentModel)")
    }

    private var currentModel: String {
        store.currentChatModelLabel
            ?? (store.isConnected ? "Model" : "Not connected")
    }

    /// Dictation writes into the draft rather than sending, so a misheard word
    /// can be fixed before the agent ever sees it.
    @ViewBuilder
    private var micButton: some View {
        // What the finger asked for, until the recogniser catches up. Starting
        // dictation sets up an audio session and a speech recogniser before
        // `isListening` turns over, and the icon was waiting for all of it —
        // long enough on a cold start to look like the tap had missed. The
        // symbol now changes on the tap and the real state takes over when it
        // arrives.
        let listening = pendingListen ?? dictation.isListening
        Button {
            micTaps += 1
            pendingListen = !listening
            let draft = store.draft
            // Off this run loop turn, so the button redraws first.
            Task {
                dictation.prime(with: draft)
                dictation.toggle { store.draft = $0 }
            }
        } label: {
            Image(systemName: listening ? "waveform" : "mic")
                .font(.system(size: 16, weight: .medium))
                .frame(width: controlHeight, height: controlHeight)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor, isActive: listening)
        }
        .buttonStyle(.plain)
        .foregroundStyle(listening ? AnyShapeStyle(store.accent.primary(scheme)) : AnyShapeStyle(.secondary))
        .glassEffect(.regular.interactive(), in: .circle)
        // Dictation starts listening before there is anything to see. The tap
        // has to be felt, or the reader is left talking at a button they are
        // not sure they pressed.
        .sensoryFeedback(.impact(weight: .medium), trigger: micTaps)
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
        .onChange(of: dictation.isListening) { _, _ in pendingListen = nil }
    }

    /// One button holds the trailing slot: send when idle, stop while a reply is
    /// streaming, and back to send as soon as there is something new to say.
    @ViewBuilder
    private var actionButton: some View {
        let sending = store.isSending
        let hasDraft = !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.draftAttachments.isEmpty
        let stopping = sending && !hasDraft

        Button {
            if stopping { store.stop() } else { store.send() }
        } label: {
            Image(systemName: stopping ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: controlHeight, height: controlHeight)
                .contentTransition(.symbolEffect(.replace))
        }
        // `.glassProminent` sizes itself, adding about 10pt of its own padding
        // around the label — measured at 44pt tall next to a 34pt chip. Applying
        // the material to an exact frame instead keeps the row one height.
        .buttonStyle(.plain)
        // The accent's clearest home: the one control that acts. With Stone
        // it resolves to the same near-black and near-white the button always
        // had, so the default look is unchanged and every other choice shows.
        .foregroundStyle(
            store.isConnected && (sending || hasDraft)
                ? store.accent.primary(scheme) : Color.secondary
        )
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("send", in: glass)
        // Not disabled while the connection is being re-made: `send()`
        // reconnects first. Disabled, a press did nothing at all.
        .disabled(!sending && !hasDraft)
        .accessibilityLabel(stopping ? "Stop" : "Send")
        .accessibilityIdentifier("composer.action")
    }
}
