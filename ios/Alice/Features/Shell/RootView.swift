import SwiftUI
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

    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0

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
                    surfaceProgress: progress,
                    onDismiss: { setDrawer(false) }
                )
                    .frame(width: drawerWidth)
                    .safeAreaPadding(EdgeInsets(
                        top: proxy.safeAreaInsets.top,
                        leading: 0,
                        bottom: proxy.safeAreaInsets.bottom,
                        trailing: 0
                    ))

                ChatScreen(
                    onOpenDrawer: { setDrawer(true) },
                    onBack: goBackToBots,
                    onOpenBots: openBots
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
                        // The corners need an edge of their own. Dimming a
                        // near-black conversation over a near-black drawer
                        // leaves three levels out of 255 between them, and the
                        // rounding measured as present while being invisible.
                        // A hairline states the shape instead of implying it.
                        RoundedRectangle(
                            cornerRadius: displayCornerRadius, style: .continuous
                        )
                        .strokeBorder(
                            Palette.border(scheme).opacity(0.55 * progress),
                            lineWidth: 0.75
                        )
                    }
                    // Rounded to the display's own radius: once it has moved, its
                    // left corners are out in the middle of the screen, and square
                    // ones there would give away that this is a flat layer rather
                    // than the phone's surface sliding aside. Continuous, because
                    // that is the curve the bezel is drawn with.
                    .clipShape(.rect(
                        cornerRadius: displayCornerRadius * progress,
                        style: .continuous
                    ))
                    // Cast to the left, onto the drawer. The hairline states
                    // where the conversation ends; this says which of the two
                    // is on top, which an edge alone cannot — two flat panels
                    // meeting at a line could be either order. Grows with the
                    // gesture so a half-open drawer is half-lit, and costs
                    // nothing at rest, where its opacity is zero.
                    .shadow(
                        color: .black.opacity(0.30 * progress),
                        radius: 22 * progress,
                        x: -10 * progress,
                        y: 0
                    )
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
                            onClose: {
                                closeBots(exitLeading: store.botsExitLeading) {}
                            },
                            onBack: {
                                closeBots(exitLeading: false) {
                                    store.goHome()
                                }
                            }
                        )
                        // Same as the conversation's: the stack's container is
                        // white by default and is what the search keyboard's
                        // corners would show.
                        .containerBackground(Palette.background(scheme), for: .navigation)
                    }
                    .background(Palette.background(scheme))
                    // The same swipe that got here from a bot's conversation,
                    // one step further out. A page you can only leave by
                    // reaching for a button is a page the thumb argues with.
                    .overlay {
                        DrawerPan(
                            shouldBegin: { velocity in
                                abs(velocity.x) > abs(velocity.y) * 1.5
                            },
                            onChange: { _ in },
                            onEnd: { translation, predicted in
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
                    // Only the arrival varies. A removal transition is read
                    // from the view as it last existed, not as it is being
                    // dismissed, so setting the direction in the same breath
                    // as closing the page had no effect: it left by whichever
                    // side it had arrived from. Backing out of a bot's chat
                    // set that to the left, and home was then uncovered from
                    // the right, against the finger, for every swipe after.
                    // Leaving is always rightward, which is what leaving is.
                    .transition(.asymmetric(
                        insertion: .move(
                            edge: store.botsFromLeading ? .leading : .trailing
                        ),
                        removal: .move(
                            edge: store.botsExitLeading ? .leading : .trailing
                        )
                    ))
                    .zIndex(1)
                }
            }
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
            .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: drawerOpen)
            .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: store.showingBots)
            // The drawer answers a sideways swipe from anywhere, not just from a
            // strip at the edge. `DrawerPan` only claims a drag that starts out
            // sideways, so scrolling the conversation is untouched.
            .overlay {
                // Gone entirely while the bots page is up, not merely told to
                // say no: both recognisers attach to the same ancestor, and
                // one swipe was being answered twice — going home and opening
                // the drawer on top of it.
                if !store.showingBots {
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
                    },
                    onEnd: { translation, predicted in
                        let travelled = abs(translation) > drawerWidth * 0.3
                        let flicked = abs(predicted) > 120
                        drag = 0
                        guard !inBotChat || drawerOpen else {
                            if travelled || flicked { goBackToBots() }
                            return
                        }
                        if !drawerOpen, translation < 0 {
                            if travelled || flicked { openBots() }
                            return
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
        !(store.activeConversation?.botName ?? "").isEmpty
    }

    /// Dismisses the bots page, one frame after settling what is behind it.
    ///
    /// Two things have to be true before the page starts moving: the exit
    /// direction, because a removal transition is read from the view as it
    /// last stood rather than as it is being dismissed; and whatever the page
    /// is uncovering. Changing the conversation in the same breath showed the
    /// old one for an instant as the page slid off, and the page left by
    /// whichever side it had arrived from.
    private func closeBots(exitLeading: Bool, _ settle: () -> Void) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        store.botsExitLeading = exitLeading
        settle()
        // Do not defer this to a later run-loop turn. On a real device the
        // page can be re-evaluated between the tap and that deferred write,
        // leaving the visible Bots layer in place even though the action fired.
        store.showingBots = false
    }

    /// Back out of a bot's conversation to the list it was opened from.
    /// Forward into the bots from Alice's own conversation: in off the right,
    /// the way anything you are moving towards should arrive.
    private func openBots() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        store.botsFromLeading = false
        store.showingBots = true
    }

    private func goBackToBots() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        store.botsFromLeading = true
        store.showingBots = true
    }

    private var offset: CGFloat {
        min(max((drawerOpen ? drawerWidth : 0) + drag, 0), drawerWidth)
    }

    private var progress: CGFloat { offset / drawerWidth }

    /// The radius of the physical display's corners.
    ///
    /// UIKit has never made this public, and the value differs across
    /// devices — so it is read from the screen where it exists and falls back
    /// to a plausible modern-iPhone radius where it does not. Getting it wrong
    /// is cosmetic: the corners simply stop matching the bezel.
    private var displayCornerRadius: CGFloat {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 55
    }

    private func setDrawer(_ open: Bool) {
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
        }
        drag = 0
        drawerOpen = open
    }
}
