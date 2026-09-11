import SwiftUI
import UIKit

struct ChatScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let onOpenDrawer: () -> Void
    let onBack: () -> Void
    let onOpenBots: () -> Void

    @FocusState private var composerFocused: Bool
    @State private var configuring: BotRow?
    @State private var homeComposerHeight: CGFloat = 120
    /// Extra room under the empty home while the keyboard is closed. The block
    /// centres in what is left, so it sits half of this higher.
    private static let restingLift: CGFloat = 56
    /// Whether an on-screen keyboard is taking room. Not the composer's focus: a
    /// hardware keyboard focuses it without taking any, and keying the lift on
    /// focus dropped the block into the space the lift had left.
    @State private var keyboardShown = false

    /// Matches the disc the navigation bar drew for these two buttons.
    private let discSize: CGFloat = 44

    /// The bot this conversation belongs to, if it belongs to one.
    private var bot: String? {
        guard let name = store.activeConversation?.botName, !name.isEmpty else {
            return nil
        }
        return name
    }

    /// A bot's mark, rasterised so a menu can show it.
    ///
    /// Kept per mark: the renderer is not free, and the same handful of faces
    /// are asked for every time the menu opens.
    private static var markImages: [BotMark: UIImage] = [:]

    @MainActor
    static func markImage(_ mark: BotMark) -> UIImage {
        if let cached = markImages[mark] { return cached }
        let renderer = ImageRenderer(
            content: BotMarkView(mark: mark, size: 26).frame(width: 26, height: 26)
        )
        renderer.scale = UITraitCollection.current.displayScale
        // Original, not template: a menu tints what it is given, and a bot's
        // mark is its colour. Flattened to the menu's own ink they would all
        // be the same silhouette.
        let image = (renderer.uiImage ?? UIImage())
            .withRenderingMode(.alwaysOriginal)
        markImages[mark] = image
        return image
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
            chatContent
            .background(Palette.background(scheme))
            // The stack's own container, which sits above every background
            // painted outside it and is system white in light mode. That white
            // is what showed around the software keyboard's rounded corners —
            // measured at 253–254 against the page's 240 — however many layers
            // were painted beneath.
            .containerBackground(Palette.background(scheme), for: .navigation)
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
        // Paint the window, not just the keyboard-resized chat content. The
        // software keyboard is translucent in places; without this full-screen
        // layer the NavigationStack's default white showed through underneath.
        // Only the colour ignores the keyboard — Home itself still reflows.
        .background {
            Palette.background(scheme)
                .ignoresSafeArea()
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
            .preferredColorScheme(store.theme.colorScheme)
        }
        // The list is where these are normally read, and a conversation can
        // be opened without ever going through it.
        .task(id: bot) { await refreshBots() }
    }

    /// A plain tap off the composer dismisses the keyboard.
    ///
    /// Attached to the transcript and the empty home, not the whole screen.
    /// On the screen it also fired for presses on the composer's own
    /// buttons, so Send closed the keyboard — sliding the button out from
    /// under the finger — instead of sending. `simultaneousGesture` leaves
    /// scrolling and text selection working underneath it.
    private var dismissKeyboard: some Gesture {
        TapGesture().onEnded { composerFocused = false }
    }

    @ViewBuilder
    private var chatContent: some View {
        if let conversation = store.activeConversation, !conversation.messages.isEmpty {
            transcript
                .simultaneousGesture(dismissKeyboard)
                // A real conversation reserves the live composer height so the
                // last message still follows attachments, extra lines, and the
                // keyboard.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(focused: $composerFocused, placeholder: placeholder)
                }
        } else {
            // The empty home should not reflow when the keyboard appears.
            // Reserve the unfocused composer height in the static layer, then
            // let the real composer follow the keyboard as a separate sibling.
            ZStack(alignment: .bottom) {
                // No keyboard-ignoring here, deliberately.
                //
                // The intent was that the home should not move at all. But
                // `ignoresSafeArea(.keyboard, edges: .bottom)` extends the
                // block *downwards* past the container while its top edge
                // stays put, so its centre fell — the logo drifted down and
                // the title ended up behind the composer. Three shapes of that
                // fix all failed the same way.
                //
                // So it centres in whatever room it has, like every other iOS
                // screen: the block rises a little when the keyboard opens and
                // settles back when it closes. Slight motion that keeps every
                // word visible beats stillness that hides the title.
                EmptyChatView()
                    // Resting a little higher with the keyboard closed. With an
                    // on-screen keyboard up the extra goes away, so the block
                    // ends exactly where it did — the lift only changes where it
                    // starts.
                    .padding(.bottom, homeComposerHeight + (keyboardShown ? 0 : Self.restingLift))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .simultaneousGesture(dismissKeyboard)
                    .animation(.smooth(duration: 0.3), value: keyboardShown)
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillShowNotification
                    )) { note in
                        let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                            .cgRectValue ?? .zero
                        // A hardware keyboard reports only its shortcut bar,
                        // which leaves the room as it was.
                        keyboardShown = frame.height > 120
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIResponder.keyboardWillHideNotification
                    )) { _ in
                        keyboardShown = false
                    }

                Composer(focused: $composerFocused, placeholder: placeholder)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard !composerFocused, height > 0,
                              abs(homeComposerHeight - height) > 0.5 else { return }
                        homeComposerHeight = height
                    }
            }
        }
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
            .accessibilityIdentifier("chat.leading")

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
                    // The back disc's height, so the two sit on one line as a
                    // pair; at 36 the name read as smaller than the button
                    // beside it.
                    .frame(height: discSize)
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
                            // Rendered to an image first. A menu is built by
                            // UIKit from the label's text and symbol, and a
                            // SwiftUI view in the icon slot is simply dropped
                            // — which is why the marks never appeared. An
                            // image it will carry.
                            Label {
                                Text(store.botCurrentName(for: other.name))
                            } icon: {
                                Image(uiImage: Self.markImage(store.mark(for: other.name)))
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
        // 20, up from 16: the discs sat a little tight against the screen's
        // edges. The drawer's search button keeps the same 20 on its side.
        .padding(.horizontal, 20)
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
                    // 34, up from 22: consecutive replies ran together, and
                    // each now carries its time above it as well.
                    LazyVStack(alignment: .leading, spacing: 34) {
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Deliberately neutral about the keyboard and about the composer.
        //
        // This used to ignore the keyboard here as well as at the call site.
        // `safeAreaInset` contributes to the bottom safe area, so ignoring
        // that area threw away the composer's reserved space along with the
        // keyboard's — and the block re-centred into the taller box, moving
        // *down* by about a composer's height and sliding the title behind it.
        // Whoever places this view owns both decisions now.
        centred
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
                Image(colorScheme == .dark ? "AliceHomeLogoDark" : "AliceHomeLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                    .padding(.bottom, 8)

                Text("What are we working on?")
                    .font(.aliceTitle(.title))
                    .multilineTextAlignment(.center)
                Text("You talk to Alice. One thing at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            // No hardcoded composer offset either: the call site already
            // reserves the real height, and 140 on top of it was a second
            // guess at the same gap.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
