import SwiftUI
import TipKit
import UIKit

/// Chat is the app; everything else is somewhere you go from it.
///
/// A tab bar would put four peers at the bottom of a screen that is really one
/// thing, so this follows the shape every model client has settled on: the
/// conversation fills the display, and history, settings and the connection
/// live behind a drawer that slides in from the left.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    @AppStorage(PerformanceHUD.key) private var showsPerformanceHUD = false
    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0
    /// Where the bots page is while it slides away; see `closeBots`.
    @State private var botsExitOffset: CGFloat = 0
    @State private var closingBots = false
    @State private var botsCloseTask: Task<Void, Never>?
    /// A row may receive its Button action after the full-screen pan ends.
    /// Keep that late action from reopening the bot we just swiped away from.
    @State private var botsRowSwipeRecognized = false
    @State private var screenWidth: CGFloat = 0
    /// Display corner radius, read once.
    @State private var cornerRadius: CGFloat = 55
    /// Full display radius for the whole time Home is away from the bezel.
    /// It turns on with the first movement and off only after the close
    /// has finished, so the curve does not grow or shrink with the slide.
    @State private var panelRounded = false
    @State private var unroundTask: Task<Void, Never>?

    private let drawerWidth: CGFloat = 300

    var body: some View {
        // Reads the window's insets before they are given up below, so the
        // drawer can be handed them back. The conversation does not need this:
        // its `NavigationStack` takes its own insets from the window.
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // The drawer sits still and the conversation slides off it. The
                // other way round — a panel sliding over a fixed conversation —
                // reads as a panel; this reads as the conversation being moved
                // aside, which is what the drawer is for.
                Sidebar(
                    width: drawerWidth,
                    onDismiss: { setDrawer(false) }
                )
                    .equatable()
                    .frame(width: drawerWidth)
                    .safeAreaPadding(EdgeInsets(
                        top: proxy.safeAreaInsets.top,
                        leading: 0,
                        bottom: proxy.safeAreaInsets.bottom,
                        trailing: 0
                    ))

                ChatScreen(
                    onOpenDrawer: { setDrawer(true) },
                    onBack: { goBackToBots() },
                    onOpenBots: { openBots() },
                    drawerProgress: progress
                )
                    .overlay {
                        // Grows with the gesture rather than appearing at the end,
                        // so the conversation hands over its prominence gradually.
                        Color.black.opacity(0.45 * progress)
                            .ignoresSafeArea()
                            // Only swallows touches once the drawer is really
                            // open, so a half-swipe never blocks the chat.
                            .allowsHitTesting(drawerOpen)
                            .onTapGesture { setDrawer(false) }
                    }
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: panelCornerRadius, style: .continuous
                        )
                        .strokeBorder(
                            Palette.border(scheme).opacity(0.55 * progress),
                            lineWidth: 0.75
                        )
                    }
                    .clipShape(.rect(
                        cornerRadius: panelCornerRadius,
                        style: .continuous
                    ))
                    .offset(x: offset)

                // Bots is a page, not a sheet. It is reached sideways — out
                // of the drawer, or by backing out of a bot's conversation —
                // and a screen rising from the bottom in answer to a swipe
                // to the right reads as the wrong screen appearing. Its own
                // `NavigationStack` so it takes its insets from the window,
                // the way the conversation does, rather than from a container
                // that has given them up.
                if store.showingBots {
                    NavigationStack {
                        // Deferred for the same reason as the gesture's: the page's
                        // exit direction and whatever it uncovers both have to
                        // be settled before it starts moving.
                        BotsScreen(
                            canOpenBot: { !botsRowSwipeRecognized },
                            onClose: {
                                closeBots(exitLeading: store.botsExitLeading) {}
                            },
                            onBack: {
                                closeBots(exitLeading: false) {
                                    store.goHome()
                                }
                            }
                        )
                        .containerBackground(Palette.background(scheme), for: .navigation)
                    }
                    .background(Palette.background(scheme))
                    // The lift that finishes the incoming swipe must not land
                    // on a section or row at the same height.
                    .allowsHitTesting(!botsRowSwipeRecognized)
                    // The same swipe that got here from a bot's conversation,
                    // one step further out. A page you can only leave by
                    // reaching for a button is a page the thumb argues with.
                    .overlay {
                        DrawerPan(
                            controlIdentifierPrefix: "bots.row.",
                            shouldBegin: { velocity in
                                abs(velocity.x) > abs(velocity.y) * 1.5
                            },
                            onChange: { _ in
                                botsRowSwipeRecognized = true
                            },
                            onEnd: { translation, predicted in
                                defer { releaseBotsRowSwipeBlock() }
                                // Leftward is forward, back into the bot you
                                // were last talking to — the page is between
                                // home and that conversation, so it should
                                // give onto both.
                                if translation < 0 || predicted < -120 {
                                    guard translation < -drawerWidth * 0.3
                                        || predicted < -120,
                                          let chat = store.lastBotConversation
                                    else { return }
                                    closeBots(exitLeading: true) {
                                        store.activeID = chat.id
                                    }
                                    return
                                }
                                guard translation > drawerWidth * 0.3
                                    || predicted > 120
                                else { return }
                                closeBots(exitLeading: false) {
                                    store.goHome()
                                }
                            }
                        )
                        .allowsHitTesting(false)
                    }
                    // Leaving is `closeBots`' explicit slide rather than a
                    // removal transition; see there for why a transition's
                    // direction could not be trusted.
                    .offset(x: botsExitOffset)
                    .transition(.asymmetric(
                        insertion: .move(
                            edge: store.botsFromLeading ? .leading : .trailing
                        ),
                        removal: .identity
                    ))
                    .zIndex(1)
                }

                // Notes is a page for the same reasons: in off the right from
                // the drawer, out by its back button or a swipe to the right,
                // and never closed by a downward swipe through the notes.
                if store.showingNotes {
                    NavigationStack {
                        NotesFoldersScreen(onClose: closeNotes)
                            .containerBackground(Palette.background(scheme), for: .navigation)
                    }
                    // Painted under the keyboard too, as the conversation is:
                    // resized to the keyboard, the page left its rounded
                    // corners showing whatever was beneath it.
                    .background {
                        Palette.background(scheme)
                            .ignoresSafeArea()
                    }
                    .overlay {
                        DrawerPan(
                            shouldBegin: { velocity in
                                !store.editingNote && !store.noteRowOpen && !store.notesFolderOpen
                                    && Date.now.timeIntervalSince(store.noteRowTouchedAt) > 0.8
                                    && velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.5
                            },
                            onChange: { _ in },
                            onEnd: { translation, predicted in
                                guard translation > drawerWidth * 0.3 || predicted > 120
                                else { return }
                                closeNotes()
                            }
                        )
                        .allowsHitTesting(false)
                    }
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
                }
            }
            // Developer › Performance meter: centred under the composer, in
            // the strip beside the home indicator, where it covers nothing.
            .overlay(alignment: .bottom) {
                if store.developerMode && showsPerformanceHUD {
                    PerformanceHUD()
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom - 26, 4))
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
            .onAppear { cornerRadius = Self.displayCornerRadius }
            // Both layers have to reach the physical edges: the drawer so it fills
            // the display behind, and the conversation so its rounded corners land
            // on the bezel rather than being cut at the status bar. The screens
            // inside still take their insets from the window, so nothing moves.
            .ignoresSafeArea()
            // At rest, the clipped conversation corners must reveal the same
            // page colour as Home. iOS 26/27 leaves those corners visible around
            // the rounded software keyboard; using the drawer card here produced
            // a pale/white halo. As the drawer opens, hand that exposed surface
            // progressively to the drawer colour instead.
            .background {
                ZStack {
                    Palette.background(scheme)
                    Palette.card(scheme).opacity(progress)
                }
                .ignoresSafeArea()
            }
            // Applied here rather than at the app, which had to guess a scheme
            // for it: on "system" it always resolved the light variant, so the
            // accent was wrong in the dark exactly where it is most visible.
            .tint(store.accent.primary(scheme))
            .fullScreenCover(item: Bindable(store).presentedLibraryTool) { tool in
                NavigationStack {
                    LibraryToolScreen(tool: tool)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { store.presentedLibraryTool = nil }
                            }
                        }
                }
                .presentationBackground(Palette.background(scheme))
                .preferredColorScheme(store.theme.colorScheme)
            }
            .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: drawerOpen)
            .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: store.showingBots)
            .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: store.showingNotes)
            // Leaving a screen puts its keyboard away. Kept up on a page with
            // no field — Agents, Notes, another chat's header — nothing on it
            // could take the focus back, so there was no way to close it.
            .onChange(of: store.showingBots) { dismissKeyboard() }
            .onChange(of: store.showingNotes) { dismissKeyboard() }
            .onChange(of: store.activeID) { dismissKeyboard() }
            .onChange(of: drawerOpen) { _, open in if open { dismissKeyboard() } }
            // The drawer answers a sideways swipe from anywhere, not just from a
            // strip at the edge. `DrawerPan` only claims a drag that starts out
            // sideways, so scrolling the conversation is untouched.
            .overlay {
                // Gone entirely while the bots page is up, not merely told to
                // say no: both recognisers attach to the same ancestor, and
                // one swipe was being answered twice — going home and opening
                // the drawer on top of it.
                if !store.showingBots && !store.showingNotes {
                    DrawerPan(
                    shouldBegin: { velocity in
                        // Sideways enough to be meant sideways.
                        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
                        if drawerOpen { return velocity.x < 0 }
                        // In a bot's conversation only the way back means
                        // anything: leftward would be going deeper into the
                        // bots from inside one of them, which is where the
                        // finger already is.
                        if inBotChat { return velocity.x > 0 }
                        // On Alice's own: right opens the drawer, left goes
                        // to the bots.
                        return true
                    },
                    onChange: { translation in
                        // In a bot's conversation the swipe is a back gesture,
                        // so nothing follows the finger: the drawer it would
                        // otherwise reveal has nothing to do with this bot.
                        guard !inBotChat || drawerOpen else { return }
                        // A leftward drag is heading for the bots page, which
                        // arrives as a page rather than by being dragged in.
                        guard drawerOpen || translation > 0 else { return }
                        drag = drawerOpen ? min(0, translation) : max(0, translation)
                        if offset > 0 {
                            unroundTask?.cancel()
                            panelRounded = true
                        }
                    },
                    onEnd: { translation, predicted in
                        let travelled = abs(translation) > drawerWidth * 0.3
                        let flicked = abs(predicted) > 120
                        drag = 0
                        guard !inBotChat || drawerOpen else {
                            if travelled || flicked { goBackToBots(fromSwipe: true) }
                            return
                        }
                        if !drawerOpen, translation < 0 {
                            if travelled || flicked {
                                SwipeNavigationTip().invalidate(reason: .actionPerformed)
                                openBots(fromSwipe: true)
                            }
                            return
                        }
                        if !drawerOpen, travelled || flicked {
                            SwipeNavigationTip().invalidate(reason: .actionPerformed)
                        }
                        setDrawer(drawerOpen ? !(travelled || flicked) : (travelled || flicked))
                    }
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .alert(
            "Couldn’t open notification",
            isPresented: Binding(
                get: { store.routeNotice != nil },
                set: { if !$0 { store.routeNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.routeNotice = nil }
        } message: {
            Text(store.routeNotice ?? "Alice could not open that notification.")
        }
    }

    /// Whether the conversation on screen belongs to a bot.
    private var inBotChat: Bool {
        !(store.activeChat.botName ?? "").isEmpty
    }

    /// Dismisses the bots page by sliding it off the side it is leaving by.
    ///
    /// Whatever the page uncovers is settled first, while it still covers
    /// the screen. The slide is then an explicit animation, and the page is
    /// only removed once it has finished, without a transition of its own.
    /// It used to leave through a removal transition whose edge came from
    /// `botsExitLeading` — but a removal transition is the one the view last
    /// rendered with, and setting the edge in the same update as closing had
    /// no effect. After opening a bot from the list (which left leftwards),
    /// backing out to the list and on to home slid the page off to the left,
    /// so home came in from the right, against the finger.
    private func closeBots(exitLeading: Bool, _ settle: () -> Void) {
        guard !closingBots else { return }
        closingBots = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        store.botsExitLeading = exitLeading
        let before = store.activeID
        settle()
        let width = max(screenWidth, 1)
        // A different chat under the page is laid out first, on a frame of
        // its own. Built in the same frame the slide started, it cost the
        // slide its first frames: the page jumped rather than moved.
        let lead: Duration = store.activeID == before ? .zero : .milliseconds(17)
        // SwiftUI's animation completion has occasionally not been delivered
        // on a physical device, leaving the fully translated Bots layer alive
        // above Home. Retire it independently of the renderer after the same
        // duration. The task is cancelled if navigation opens Bots again.
        botsCloseTask?.cancel()
        botsCloseTask = Task { @MainActor in
            do {
                if lead > .zero { try await Task.sleep(for: lead) }
                withAnimation(.snappy(duration: 0.3, extraBounce: 0.02)) {
                    botsExitOffset = exitLeading ? -width : width
                }
                try await Task.sleep(for: .milliseconds(320))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) {
                store.showingBots = false
                botsExitOffset = 0
            }
            closingBots = false
            botsCloseTask = nil
        }
    }

    /// Back out of a bot's conversation to the list it was opened from.
    /// Forward into the bots from Alice's own conversation: in off the right,
    /// the way anything you are moving towards should arrive.
    private func openBots(fromSwipe: Bool = false) {
        botsCloseTask?.cancel()
        botsCloseTask = nil
        closingBots = false
        botsRowSwipeRecognized = fromSwipe
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        botsExitOffset = 0
        store.botsFromLeading = false
        store.showingBots = true
        store.markNoticesSeen(.agents)
        if fromSwipe { releaseBotsRowSwipeBlock() }
    }

    private func goBackToBots(fromSwipe: Bool = false) {
        botsCloseTask?.cancel()
        botsCloseTask = nil
        closingBots = false
        botsRowSwipeRecognized = fromSwipe
        store.markActiveBotRead()
        store.markNoticesSeen(.agents)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        botsExitOffset = 0
        store.botsFromLeading = true
        store.showingBots = true
        if fromSwipe { releaseBotsRowSwipeBlock() }
    }

    /// UIKit can deliver a Button's release just after the pan's `.ended`,
    /// including onto a page that appeared under the same finger. Hold the
    /// page deaf until that lift has passed, without making a later tap
    /// feel dead.
    private func releaseBotsRowSwipeBlock() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            botsRowSwipeRecognized = false
        }
    }

    /// Notes leaves the way it came in, off the right.
    private func closeNotes() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.snappy(duration: 0.3, extraBounce: 0.02)) {
            store.showingNotes = false
        }
    }

    private var offset: CGFloat {
        min(max((drawerOpen ? drawerWidth : 0) + drag, 0), drawerWidth)
    }

    private var progress: CGFloat { offset / drawerWidth }

    /// The display radius whenever Home is out from under the bezel, including
    /// the first frame of the open and the last frame of the close.
    private var panelCornerRadius: CGFloat {
        panelRounded ? cornerRadius : 0
    }

    private static var displayCornerRadius: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 55
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func setDrawer(_ open: Bool) {
        let wasOpen = drawerOpen
        if drawerOpen != open {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        if open {
            // The keyboard would otherwise stay up behind the drawer, with
            // focus on a field the drawer is covering.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
            unroundTask?.cancel()
            // The radius has to be the display radius before the slide
            // starts. Setting both in one update lets the slide animation
            // grow the curve on the way open.
            if !panelRounded {
                panelRounded = true
                drag = 0
                Task { @MainActor in
                    drawerOpen = true
                }
                return
            }
        }
        drag = 0
        drawerOpen = open
        if open { return }
        if wasOpen {
            // Stay rounded until the slide has finished and Home is back
            // under the bezel. Turning it off with the close would square
            // the corners while they are still in the middle of the screen.
            unroundTask?.cancel()
            unroundTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled, !drawerOpen, drag == 0 else { return }
                panelRounded = false
            }
        } else {
            panelRounded = false
        }
    }
}
