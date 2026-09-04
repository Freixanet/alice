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
                Sidebar(width: drawerWidth, onDismiss: { setDrawer(false) })
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
                        cornerRadius: displayCornerRadius, style: .continuous
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
                        BotsScreen(onClose: { store.showingBots = false })
                    }
                    .background(Palette.background(scheme))
                    // The same swipe that got here from a bot's conversation,
                    // one step further out. A page you can only leave by
                    // reaching for a button is a page the thumb argues with.
                    .overlay {
                        DrawerPan(
                            shouldBegin: { velocity in
                                abs(velocity.x) > abs(velocity.y) * 1.5
                                    && velocity.x > 0
                            },
                            onChange: { _ in },
                            onEnd: { translation, predicted in
                                guard translation > drawerWidth * 0.3
                                    || predicted > 120
                                else { return }
                                UIImpactFeedbackGenerator(style: .soft)
                                    .impactOccurred()
                                store.goHome()
                                // Home is behind this page, so the page has
                                // to move the way the finger did — off the
                                // right — and uncover it from the left.
                                // Leaving by the left uncovered home from the
                                // right, against the gesture.
                                store.botsFromLeading = false
                                store.showingBots = false
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
                        removal: .move(edge: .trailing)
                    ))
                    .zIndex(1)
                }
            }
            // Both layers have to reach the physical edges: the drawer so it fills
            // the display behind, and the conversation so its rounded corners land
            // on the bezel rather than being cut at the status bar. The screens
            // inside still take their insets from the window, so nothing moves.
            .ignoresSafeArea()
            // The drawer's own surface, because this is what the conversation's
            // rounded corners cut through to. Painting the page background here
            // left the corners opening onto nothing — a wedge of a colour that
            // belongs to neither layer.
            .background(Palette.card(scheme))
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
    }

    /// Whether the conversation on screen belongs to a bot.
    private var inBotChat: Bool {
        !(store.activeConversation?.botName ?? "").isEmpty
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
