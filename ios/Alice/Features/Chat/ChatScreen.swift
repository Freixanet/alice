import SwiftUI

struct ChatScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let onOpenDrawer: () -> Void
    let onBack: () -> Void
    let onOpenBots: () -> Void

    @FocusState private var composerFocused: Bool
    @State private var configuring: BotRow?

    /// Matches the disc the navigation bar drew for these two buttons.
    private let discSize: CGFloat = 44

    /// The bot this conversation belongs to, if it belongs to one.
    private var bot: String? {
        guard let name = store.activeConversation?.botName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// Every bot except the one already on screen.
    private var otherBots: [BotRow] {
        store.cachedBots.filter { $0.name != bot }
    }

    private var placeholder: String {
        guard let bot = store.activeConversation?.botName, !bot.isEmpty else {
            return "Talk to Alice…"
        }
        return "Ask \(store.botCurrentName(for: bot))…"
    }

    var body: some View {
        NavigationStack {
            transcript
                // A plain tap anywhere off the composer dismisses the
                // keyboard; `simultaneousGesture` leaves scrolling and text
                // selection working underneath it.
                .simultaneousGesture(
                    TapGesture().onEnded { composerFocused = false }
                )
                // `safeAreaInset` rather than a layer in a `ZStack`. Overlaid,
                // the composer had to be compensated for with a fixed 120pt
                // of empty space under the transcript — a guess that is wrong
                // the moment the composer grows for an attachment, a second
                // line, or the command list, and wrong again when the keyboard
                // pushes it up. The inset reserves whatever height it actually
                // has. Content still scrolls underneath it; it just no longer
                // comes to rest there.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(focused: $composerFocused, placeholder: placeholder)
                }
            .background(Palette.background(scheme))
            .contentShape(.rect)
            .navigationBarTitleDisplayMode(.inline)
            // The bar's own buttons cannot be moved down: iOS 26 draws
            // their glass circles from the bar itself, so offsetting a
            // toolbar button slides the glyph out of a disc that stays put.
            // They are laid out here instead, with the same 44pt disc and
            // the same glass the composer's controls use.
            .toolbar(.hidden, for: .navigationBar)
            // `safeAreaInset` rather than an overlay: it both places the
            // controls and reserves their height, which is the half the
            // navigation bar was quietly doing. As an overlay the first
            // message sat underneath the new-chat button.
            .safeAreaInset(edge: .top, spacing: 0) { topControls }
        }
        // The whole settings page, not a shortlist of it. A menu here made
        // the reader choose between the four things it offered and the
        // twenty the page has, having been given no way to tell which was
        // which — and the name of a thing is where you expect to find all of
        // it, not a summary.
        .sheet(item: $configuring) { bot in
            NavigationStack {
                BotDetail(bot: bot, onChange: { Task { await refreshBots() } })
            }
        }
        // The list is where these are normally read, and a conversation can
        // be opened without ever going through it.
        .task(id: bot) { await refreshBots() }
    }

    /// Keeps `cachedBots` good enough for the settings page to open from here.
    private func refreshBots() async {
        guard bot != nil, store.dashboardReady else { return }
        _ = try? await store.bots()
    }

    private var topControls: some View {
        HStack(spacing: 0) {
            Button(action: bot == nil ? onOpenDrawer : onBack) {
                // Two bars, not three, matched to the `plus` across from it.
                // Both are math symbols, so the pairing is a real one — but
                // not at the same settings: `equal` at 18pt medium matches
                // the plus's 1.88pt stroke on bars 2pt too short, and going
                // up a size to fix the width thickens it past the plus. 20pt
                // regular lands on both. (`line.3.horizontal`, the usual menu
                // glyph, is a different family and drew at 1.25pt, reading
                // thin beside it.)
                // A bot's conversation is somewhere you arrived at from the
                // list of bots, not a place the drawer leads anywhere useful
                // from — so from here the same disc goes back instead.
                Image(systemName: bot == nil ? "equal" : "chevron.left")
                    .font(.system(size: 20, weight: bot == nil ? .regular : .medium))
                    .imageScale(.large)
                    .frame(width: discSize, height: discSize)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(bot == nil ? "Chats" : "Bots")

            Spacer(minLength: 0)

            // Whose conversation this is. Alice's own mark when it is hers —
            // the drawer already says "Alice", so a second wordmark here would
            // be one too many — and the bot's mark and name when it is not.
            if let bot {
                Button {
                    configuring = store.cachedBots.first { $0.name == bot }
                } label: {
                    HStack(spacing: 8) {
                        BotMarkView(mark: store.mark(for: bot), size: 24)
                        Text(store.botCurrentName(for: bot))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .accessibilityHint("Opens this bot’s settings")
                // Held rather than tapped: the other bots. The name is where
                // you look to know whose conversation this is, so it is also
                // where you would look to make it somebody else's — and a
                // press-and-hold adds that without taking the tap away from
                // the settings it already opens.
                .contextMenu {
                    ForEach(otherBots) { other in
                        Button {
                            store.openBotConversation(for: other)
                        } label: {
                            // Their own faces. An arrow says "switch", which
                            // the menu already says by existing; the mark says
                            // which bot, which is the only question here.
                            Label {
                                Text(store.botCurrentName(for: other.name))
                            } icon: {
                                BotMarkView(mark: store.mark(for: other.name), size: 22)
                            }
                        }
                    }
                }
            } else {
                AliceMark(size: 30)
                    .foregroundStyle(.primary)
                    // Its ink sits 0.75pt above the two glyphs either side,
                    // the flags being lighter than the body they sit over.
                    .offset(y: 0.75)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            // Where a bot's conversation has nothing to put here — it came
            // from the bots and goes back with the chevron opposite — Alice's
            // own gets the way in, so the list is one tap from the place you
            // start, not two through a drawer.
            if bot == nil {
                Button(action: onOpenBots) {
                    // The bots' own eyes rather than a symbol standing in
                    // for them. Every bot in the app is a face with these two
                    // marks in it, so the disc that leads to them reads as one
                    // of them — a small bot sitting in the corner — instead of
                    // as a generic pair of shoulders.
                    // Stated, not inherited. `.primary` inside the glass came
                    // out at a fifth of the contrast the glyph opposite has —
                    // the disc's own vibrancy lightens what it holds, and a
                    // shape fill takes more of that than a symbol stroke does.
                    BotFaceView(
                        size: 32,
                        ink: scheme == .dark ? .white : .black
                    )
                    .frame(width: discSize, height: discSize)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Bots")
            } else {
                Color.clear
                    .frame(width: discSize, height: discSize)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 11)
        // Something for the conversation to disappear into. The edge effect
        // has nothing to work against when the bar behind these two discs is
        // transparent, so a message scrolling past simply collided with them.
        //
        // Taller than the controls and anchored to the top, so the fade runs
        // out below them: sized to the bar alone it ended exactly where the
        // first line of a message begins, which is where they were colliding.
        .background(alignment: .top) {
            // The vanishing point sits above the discs, not below them.
            // Opaque as far down as they reached, the glass had nothing to
            // refract: text was already gone by the time it got there, and
            // two discs over a flat colour are just two flat circles. Solid
            // across the status bar, out by the time the discs end, so a line
            // of a message passes behind them in view and disappears over
            // the top instead.
            LinearGradient(
                stops: [
                    .init(color: Palette.background(scheme), location: 0),
                    .init(color: Palette.background(scheme), location: 0.42),
                    .init(color: Palette.background(scheme).opacity(0), location: 0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 132)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            ScrollViewReader { proxy in
              GeometryReader { area in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(conversation.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        // Air between the last reply and the composer, so the
                        // conversation ends rather than stopping against the
                        // glass.
                        Color.clear.frame(height: 34).id(bottomAnchor)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 28)
                    // At least a screenful, aligned to the top. Without this
                    // the bottom anchor pinned a short conversation to the
                    // foot of the view and left a screen of nothing above it;
                    // now only a conversation long enough to overflow sticks
                    // to the bottom, which is the whole point of the anchor.
                    .frame(minHeight: area.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
                // On the scroll view itself, where the effect has an edge to
                // work against. On the container outside it, text ran under
                // the top controls with nothing between them.
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                // Opens on the newest message and stays there.
                //
                // The plain form, not `.sizeChanges`. The keyboard does not
                // resize this scroll view — the composer is a safe-area inset,
                // so what grows is the inset, and an anchor watching for size
                // changes never fires. This one follows the inset, which is
                // what was wanted all along. And only this one: pairing it
                // with a scroll driven by focus moved the conversation twice
                // for one keystroke, which is what read as broken.
                .defaultScrollAnchor(.bottom)
                .onChange(of: conversation.messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
              }
            }
        } else {
            EmptyChatView()
        }
    }

    private var bottomAnchor: String { "bottom" }
}

private struct EmptyChatView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        centred
            // An empty chat has nothing for the composer to cover, so there is
            // no reason for it to move out of the way. Centred in a safe area
            // the keyboard shrinks, the title lifted every time the keyboard
            // opened — motion in answer to nothing.
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private var centred: some View {
        if let botName = store.activeConversation?.botName, !botName.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                BotMarkView(mark: store.mark(for: botName), size: 84, animated: true)
                Text(store.botCurrentName(for: botName))
                    // The same face the app's own title wears.
                    .font(.aliceTitle(.title))
                let liveDetail = store.cachedBots.first(where: { $0.name == botName })?.detail ?? ""
                if !liveDetail.isEmpty {
                    Text(liveDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("What are we working on?")
                    .font(.aliceTitle(.title))
                    .multilineTextAlignment(.center)
                Text("You talk to Alice. One thing at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 140)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
