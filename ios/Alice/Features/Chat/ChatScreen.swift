import SwiftUI
import TipKit
import UIKit

struct ChatScreen: View {
    let onOpenDrawer: () -> Void
    let onBack: () -> Void
    let onOpenBots: () -> Void
    /// How far the drawer is open, 0 to 1, as it moves.
    var drawerProgress: CGFloat = 0

    var body: some View {
        ChatScreenContent(
            onOpenDrawer: onOpenDrawer, onBack: onBack, onOpenBots: onOpenBots
        )
        .equatable()
        .environment(\.aliceDrawerProgress, drawerProgress)
    }
}

/// The conversation itself. It must not read the drawer gesture: rebuilding
/// home on every frame of the slide flashes a scroll indicator in the middle
/// of the screen.
private struct ChatScreenContent: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

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
    /// Whether an on-screen keyboard is taking room. Not the composer's focus:
    /// a hardware keyboard focuses it without taking any.
    @State private var keyboardShown = false

    /// Matches the disc the navigation bar drew for these two buttons.
    private let discSize: CGFloat = 44

    /// Alice's own Today chat (`AppStore.openToday`): an agent chat in how it
    /// reads and sends, Alice's in how it looks and where Back leads.
    private var isToday: Bool { bot == AppStore.todayProfile }

    /// The bot this conversation belongs to, if it belongs to one.
    private var bot: String? {
        guard let name = store.activeChat.botName, !name.isEmpty else {
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
        guard let bot = store.activeChat.botName, !bot.isEmpty else {
            return "Talk to Alice…"
        }
        return "Ask \(store.botCurrentName(for: bot))…"
    }

    private var hasTranscript: Bool {
        guard let conversation = store.shownConversation else { return false }
        return !conversation.messages.isEmpty
    }

    var body: some View {
        // Kept built under Notes and Agents. Swapping it for a blank page
        // while they covered it emptied Home in full view as a page slid in,
        // and rebuilt all of it the moment one slid away. What made it worth
        // tearing down — every change to any chat redrew it — is gone: it
        // reads only the chat on screen (`AppStore.shownConversation`).
        liveChat
    }

    private var liveChat: some View {
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
            .modifier(ChatTopChrome(scrolling: hasTranscript) {
                VStack(spacing: 8) {
                    topControls
                    // In the page, not floating over it: a popover tip is
                    // presented, and while it is, a tap anywhere else only
                    // dismisses it — the header's buttons stopped answering.
                    if bot == nil {
                        TipView(SwipeNavigationTip())
                            .padding(.horizontal, 16)
                    }
                }
            })
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
        .task(id: bot) {
            await refreshBots()
            if let bot { await store.prepareBotChatIfNeeded(profile: bot) }
        }
        // Alice's own chat is resumed as it opens, keyed by the conversation
        // so moving between two home chats warms each. The task above keys
        // on the bot and would not fire again for a second home chat.
        .task(id: store.activeID) {
            guard bot == nil, let id = store.activeID else { return }
            await store.prepareHomeChatIfNeeded(conversationID: id)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification
        )) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?
                .cgRectValue ?? .zero
            keyboardShown = frame.height > 120
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification
        )) { _ in
            keyboardShown = false
        }
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
        if let conversation = store.shownConversation, !conversation.messages.isEmpty {
            transcript
                .simultaneousGesture(dismissKeyboard)
                // A real conversation reserves the live composer height so the
                // last message still follows attachments, extra lines, and the
                // keyboard.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(
                        focused: $composerFocused,
                        placeholder: placeholder,
                        keyboardShown: keyboardShown
                    )
                }
        } else {
            // Home is centred in the room between the header and the composer,
            // in both states: its space shrinks with the keyboard exactly as
            // the composer's does. At rest it keeps the extra lift that has
            // always sat it a little above centre; with the keyboard up the
            // gap is small enough that the block takes the middle of it.
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay {
                        EmptyChatView(keyboardShown: keyboardShown)
                            .padding(.bottom, homeComposerHeight + (keyboardShown ? 0 : Self.restingLift))
                    }
                    .contentShape(.rect)
                    .simultaneousGesture(dismissKeyboard)

                VStack(spacing: 0) {
                    if bot == nil, !keyboardShown {
                        HomeSuggestionStrip()
                    }
                    Composer(
                        focused: $composerFocused,
                        placeholder: placeholder,
                        keyboardShown: keyboardShown
                    )
                }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard !composerFocused, height > 0,
                              abs(homeComposerHeight - height) > 0.5 else { return }
                        homeComposerHeight = height
                    }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Keeps `cachedBots` good enough for the settings page to open from here.
    private func refreshBots() async {
        guard bot != nil, store.dashboardReady else { return }
        _ = try? await store.bots()
    }

    private var topControls: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: bot == nil ? onOpenDrawer : (isToday ? { store.goHome() } : onBack)) {
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
                Group {
                    if bot == nil {
                        // The two bars turn into an X as the drawer opens,
                        // following the finger rather than switching at the end.
                        DrawerOpenMark()
                    } else {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .medium))
                            .imageScale(.large)
                    }
                }
                .frame(width: discSize, height: discSize)
                // The whole disc takes the tap. A stroked shape is hit only
                // where it is drawn, and the two thin bars were missed.
                .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(bot == nil ? "Chats" : (isToday ? "Home" : "Agents"))
            .accessibilityIdentifier("chat.leading")

            Spacer(minLength: 0)

            // Whose conversation this is. The same portrait-and-name as
            // Alice's own chat, so a bot's room is not a smaller kind of thing.
            // Today is Alice's own, so it wears her face.
            if isToday {
                AliceAvatar()
            } else if let bot {
                Button {
                    configuring = store.cachedBots.first { $0.name == bot }
                } label: {
                    ChatHeaderAvatar(name: store.botCurrentName(for: bot)) {
                        BotMarkView(mark: store.mark(for: bot), size: 72)
                    }
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
                AliceAvatar()
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
                    .contentShape(.circle)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Agents")
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
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = store.shownConversation, !conversation.messages.isEmpty {
            // A fresh transcript for every conversation. Reusing one scroll view
            // across chats carried the old chat's offset into the new one, and
            // a lazy stack scrolled by code alone did not draw the rows at that
            // offset: a bot chat opened blank until the reader moved it.
            TranscriptView(
                conversation: conversation,
                quietRuns: store.quietRoutineRuns[conversation.routedBotName ?? ""] ?? [],
                keyboardShown: keyboardShown
            )
                .id(conversation.id)
        } else {
            EmptyChatView()
        }
    }

}

/// One conversation's messages, scrolled.
///
/// Positioned by the scroll view itself rather than by scrolling to an id by
/// hand. The hand-driven version reasserted a far anchor over several frames
/// while lazy rows were still measuring; on a phone it could land short, and
/// a press on the jump button during a flick took several tries.

private enum DrawerProgressKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private extension EnvironmentValues {
    var aliceDrawerProgress: CGFloat {
        get { self[DrawerProgressKey.self] }
        set { self[DrawerProgressKey.self] = newValue }
    }
}

/// Follows the drawer without rebuilding the conversation under it.
private struct DrawerOpenMark: View {
    @Environment(\.aliceDrawerProgress) private var progress

    var body: some View {
        DrawerGlyph(progress: progress)
            .stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
            .frame(width: 17, height: 17)
    }
}

/// The drawer button's two bars, and the X they become.
///
/// At 0 the bars of the `equal` sign it replaced: level, a little apart. At 1
/// they meet in the middle, turned 45° either way. Animatable, so the drawer's
/// own animation carries it when it opens or closes without a finger on it.
private struct DrawerGlyph: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(max(progress, 0), 1)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // Bars 15pt long, 6.5pt apart, as `equal` draws at 20pt.
        let half: CGFloat = 7.5 + 1 * t
        let gap: CGFloat = 3.25 * (1 - t)
        var path = Path()
        for (sign, angle) in [(-1.0, Double.pi / 4), (1.0, -Double.pi / 4)] {
            let turn = CGFloat(angle) * t
            let dx = cos(turn) * half
            let dy = sin(turn) * half
            let y = centre.y + CGFloat(sign) * gap
            path.move(to: CGPoint(x: centre.x - dx, y: y - dy))
            path.addLine(to: CGPoint(x: centre.x + dx, y: y + dy))
        }
        return path
    }
}

private struct TranscriptView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let conversation: Conversation
    /// This bot's routine runs that found nothing, shown as cards.
    var quietRuns: [QuietRoutineRun] = []
    var keyboardShown = false

    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether the transcript keeps to its live edge as it grows. Only the
    /// reader turns it off, by scrolling up: then new output must not drag
    /// them back down. Until they do, nothing that grows the chat — a reply
    /// landing whole, a tool appearing, the composer or keyboard rising — may
    /// leave the latest message underneath the composer.
    @State private var following = true
    /// The reader's finger, or its flick, is what is moving the transcript.
    @State private var readerScrolling = false
    /// The transcript's end as last measured, for decisions made a moment later.
    @State private var lastTail: Tail?

    private static func isReader(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }
    /// Set the first time the transcript reaches its live edge, so the jump
    /// button does not flash while a long chat is still settling on open.
    @State private var settled = false

    /// Where the end of the transcript is, against what can be seen of it.
    private struct Tail: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        /// Close enough that the reader is still reading the end.
        let near: Bool
        /// Nothing left underneath the composer.
        let atEnd: Bool
    }

    /// How many messages are laid out at a time, and added per "earlier".
    private static let page = 80
    @State private var shown = TranscriptView.page

    private var presentedMessages: [Message] {
        RoutineDelivery.present(
            conversation.messages, botName: conversation.botName, quietRuns: quietRuns,
            agentAnswers: Set(conversation.agentAnswerIDs ?? [])
        )
    }
    var body: some View {
        // Read once per redraw: presenting walks the whole history, and the
        // page, the count above it and the rows each asked for it again.
        let presented = presentedMessages
        let hiddenCount = max(0, presented.count - shown)
        let messages = Array(presented.suffix(shown))
        GeometryReader { area in
            ScrollView {
                // Bounded pages of messages, laid out lazily so a Radar report
                // does not force every visible row to measure at once. Earlier
                // history still loads with the button below — a years-long chat
                // is never all in the view.
                LazyVStack(alignment: .leading, spacing: 34) {
                    if hiddenCount > 0 {
                        Button {
                            shown += Self.page
                        } label: {
                            Text("Show \(min(hiddenCount, Self.page)) earlier messages")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .frame(maxWidth: .infinity)
                    }
                    // The agent's replies to one request are one task, shown as
                    // one message (`ChatTasks`): one time at its top, actions
                    // once at its end over all of it. While the latest task is
                    // still going — a reply being written, or work behind the
                    // scenes — it has neither.
                    let positions = ChatTasks.positions(messages)
                    let latestBusy = !store.backgroundWork(for: conversation.id).isEmpty
                        || messages.last?.pending == true
                    ForEach(messages) { message in
                        let position = positions[message.id]
                        let busy = (position?.isLatest ?? false) && latestBusy
                        MessageRow(
                            message: message,
                            showsActions: (position?.isLast ?? true) && !busy,
                            showsTime: (position?.isFirst ?? true) && !busy,
                            showsAuthor: position?.isFirst ?? true,
                            actionsContent: position?.text
                        )
                        // Parts of one task sit closer than separate messages.
                        .padding(.top, (position?.isFirst ?? true) ? 0 : -18)
                        .id(message.id)
                    }
                    if conversation.messages.contains(where: { $0.role == .user }) {
                        TipView(MessageActionsTip())
                    }
                    BackgroundWorkCard(conversationID: conversation.id)
                    // A question the agent is waiting on, where the reply
                    // it holds up would appear.
                    ChatQuestionsCard(conversationID: conversation.id)
                }
                // The composer's own side inset, so the conversation and the
                // field it is written in share one column.
                .padding(.horizontal, store.activeBotProfileForModelSelection != nil ? 20 : 18)
                // Air under the header, so the first message does not start
                // against the agent's portrait and name. The header is a bar
                // laid over the transcript with no spacing of its own; close
                // to the gap between messages, a little less so the chat still
                // reads as starting there.
                .padding(.top, 28)
                // Air between the last reply and the composer, so the
                // conversation ends rather than stopping against the glass.
                // At rest the field sits on the home indicator and needs a
                // little more room than when the keyboard has lifted it.
                .padding(.bottom, keyboardShown ? 52 : 56)
                // At least a screenful, aligned to the top, so a short
                // conversation is not pinned to the foot of the view.
                .frame(minHeight: area.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            // The transcript extends under the Dynamic Island, the header and
            // the composer. A progressive blur there — deepening to the edge,
            // under the glass controls and over the replies — in place of the
            // system's soft edge, and only once something scrolls beneath it.
            .scrollEdgeEffectHidden(true, for: [.top, .bottom])
            .overlay {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        ProgressiveBlur(edge: .top, wash: Palette.background(scheme))
                            .frame(height: proxy.safeAreaInsets.top + 18)
                        Spacer(minLength: 0)
                        ProgressiveBlur(edge: .bottom, wash: Palette.background(scheme))
                            .frame(height: proxy.safeAreaInsets.bottom + 18)
                    }
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background { ReplySelectionDismiss() }
            .onScrollPhaseChange { oldPhase, phase in
                readerScrolling = Self.isReader(phase)
                // Once the reader lets go, where they left it decides. The
                // geometry that crossed the line can arrive before the phase
                // that says who was moving it.
                if Self.isReader(oldPhase), !readerScrolling, let lastTail {
                    following = lastTail.near
                }
            }
            .onScrollGeometryChange(for: Tail.self) { geometry in
                // The visible rect runs under the top controls and the
                // composer, which are insets, so the end is reached when the
                // last message clears the composer. Measured from the offset
                // and the container instead, a chat at its very end read as
                // 270pt short of it.
                let below = geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.visibleRect.maxY
                return Tail(
                    contentHeight: geometry.contentSize.height.rounded(),
                    viewportHeight: geometry.containerSize.height.rounded(),
                    near: below < 120, atEnd: below < 2
                )
            } action: { old, tail in
                lastTail = tail
                if tail.near { settled = true }
                let grew = tail.contentHeight != old.contentHeight
                    || tail.viewportHeight != old.viewportHeight
                if readerScrolling || !grew {
                    // Only the offset moved: the reader, or the jump button.
                    following = tail.near
                    return
                }
                // Arriving at the end moves the insets too; being there is
                // still being at the end.
                if tail.near { following = true }
                guard following, !tail.atEnd else { return }
                // Grown past the edge with nobody moving it. Watching only the
                // text missed a reply that landed whole, tools, notes and the
                // composer growing — and a jump bigger than the near-bottom
                // reach used to switch following off first.
                //
                // Decided a moment later, not in this frame: a drag's first
                // frame arrives before its phase, and the insets shift as it
                // starts, which reads as growth. Pulled straight back to the
                // end, the reader could not scroll up at all.
                Task { @MainActor in
                    guard !readerScrolling, following, lastTail?.atEnd == false else { return }
                    position.scrollTo(edge: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                ZStack {
                    if settled && !following {
                        Button {
                            position.scrollTo(edge: .bottom)
                        } label: {
                            // A 44pt disc with 12pt of reach around it. On a
                            // phone, presses a few points off the disc landed
                            // on the transcript beneath and did nothing.
                            Image(systemName: "arrow.down")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .padding(12)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Jump to latest message")
                        .accessibilityIdentifier("chat.scrollToBottom")
                        .padding(.bottom, 2)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                // Animates the button only. On the scroll view, every crossing
                // of the near-bottom line — which is the moment a reader starts
                // scrolling up — animated whatever the transcript's layout was
                // doing in that instant, and the conversation lurched.
                .animation(.snappy(duration: 0.2), value: settled && !following)
            }
        }
    }
}

/// A scrolling transcript uses a safe-area *bar* so replies pass under the
/// Dynamic Island and the system edge effect can start there. An empty home
/// still uses an inset: without a scroll view the bar would let the title
/// centre under the discs.
private struct ChatTopChrome<Header: View>: ViewModifier {
    let scrolling: Bool
    var header: Header

    init(scrolling: Bool, @ViewBuilder header: () -> Header) {
        self.scrolling = scrolling
        self.header = header()
    }

    func body(content: Content) -> some View {
        if scrolling {
            content.safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { header }
        }
    }
}

/// A tap anywhere outside a selected reply clears the handles. The text view
/// keeps them until something resigns it, and a tap on the transcript does not.
private struct ReplySelectionDismiss: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = ReplySelectionAnchor()
        view.isUserInteractionEnabled = false
        view.onEnterHierarchy = { [coordinator = context.coordinator] host in
            coordinator.attach(near: host)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

private final class ReplySelectionAnchor: UIView {
    var onEnterHierarchy: ((UIView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onEnterHierarchy?(self) }
    }
}

extension ReplySelectionDismiss {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var host: UIView?
        private var tap: UITapGestureRecognizer?

        func attach(near anchor: UIView) {
            guard tap == nil, let host = Self.controllerView(from: anchor) else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            host.addGestureRecognizer(tap)
            self.host = host
            self.tap = tap
        }

        func detach() {
            if let tap { host?.removeGestureRecognizer(tap) }
            tap = nil
            host = nil
        }

        @MainActor
        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let root = tap.view else { return }
            let hit = root.hitTest(tap.location(in: root), with: nil)
            Self.clearSelections(in: root, keeping: Self.textView(containing: hit))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        private static func controllerView(from anchor: UIView) -> UIView? {
            var responder: UIResponder? = anchor
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller.view }
                responder = next
            }
            return anchor.superview
        }

        private static func textView(containing hit: UIView?) -> UITextView? {
            var current = hit
            while let view = current {
                if let text = view as? UITextView, !text.isEditable { return text }
                current = view.superview
            }
            return nil
        }

        private static func clearSelections(in view: UIView, keeping kept: UITextView?) {
            if let text = view as? UITextView, !text.isEditable, text !== kept {
                if text.isFirstResponder || text.selectedRange.length > 0 {
                    text.selectedTextRange = nil
                    text.resignFirstResponder()
                }
            }
            for child in view.subviews {
                clearSelections(in: child, keeping: kept)
            }
        }
    }
}

private struct EmptyChatView: View {
    @Environment(AppStore.self) private var store
    @State private var showingConnection = false
    /// Home pins give way while the software keyboard is up.
    var keyboardShown = false

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
            .sheet(isPresented: $showingConnection) {
                ConnectView()
                    .preferredColorScheme(store.theme.colorScheme)
            }
    }

    @ViewBuilder
    private var centred: some View {
        if let botName = store.activeChat.botName, !botName.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Text("What are we working on?")
                    .font(.aliceTitle(.title))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                let liveDetail = store.cachedBots.first(where: { $0.name == botName })?.detail ?? ""
                if !liveDetail.isEmpty {
                    Text(liveDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("What are we working on?")
                    .font(.aliceTitle(.title))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                Text("You talk to Alice. One thing at a time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)

                if store.gatewayURL.isEmpty {
                    Button("Connect to Hermes") { showingConnection = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("home.connect")
                        .padding(.top, 12)
                        .padding(.horizontal, 32)
                }
                if !store.homeShortcuts.isEmpty, !keyboardShown {
                    HomeShortcutsShelf()
                        .padding(.top, 32)
                        .transition(.opacity)
                }
                Spacer()
            }
            .animation(.snappy(duration: 0.22), value: keyboardShown)
            // No hardcoded composer offset either: the call site already
            // reserves the real height, and 140 on top of it was a second
            // guess at the same gap.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Sits just above the composer.
private struct HomeSuggestionStrip: View {
    @Environment(AppStore.self) private var store

    private var suggestions: [HomeSuggestion] {
        HomeSuggestions.make(
            events: store.activity,
            questions: (store.notesSnapshot?.notes ?? []).compactMap { note in
                guard !note.openQuestions.isEmpty else { return nil }
                let label = note.summary.isEmpty
                    ? note.openQuestions[0]
                    : note.summary
                return HomeNotePrompt(id: note.id, label: label)
            },
            todayUnread: store.todayUnread,
            agentsWithNews: store.agentsWithNews
        )
    }

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(suggestions) { suggestion in
                    Button {
                        open(suggestion)
                    } label: {
                        Label(suggestion.title, systemImage: suggestion.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .accessibilityIdentifier("home.suggestions")
        }
    }

    private func open(_ suggestion: HomeSuggestion) {
        switch suggestion.action {
        case .routines:
            store.requestedDestination = .routines
        case .notes:
            store.showingNotes = true
        case let .note(id):
            // Read by the notes page as it appears: it opens this note.
            store.requestedNote = id
            store.showingNotes = true
        case .agents:
            store.requestedDestination = .bots
        case let .conversation(id):
            store.openConversation(id)
        case .usage:
            store.requestedDestination = .usage
        case .today:
            store.openToday()
        case let .agent(slug):
            if let bot = store.cachedBots.first(where: { $0.name == slug }) {
                store.openBotConversation(for: bot)
            } else {
                store.requestedDestination = .bots
            }
        }
    }
}
