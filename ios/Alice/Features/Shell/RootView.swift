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
                    onBack: goBackToBots
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
                    .transition(.move(edge: .leading))
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
                DrawerPan(
                    shouldBegin: { velocity in
                        guard !store.showingBots else { return false }
                        // Sideways enough to be meant sideways, and pointing the
                        // way the drawer can actually move from here.
                        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
                        return drawerOpen ? velocity.x < 0 : velocity.x > 0
                    },
                    onChange: { translation in
                        // In a bot's conversation the swipe is a back gesture,
                        // so nothing follows the finger: the drawer it would
                        // otherwise reveal has nothing to do with this bot.
                        guard !inBotChat || drawerOpen else { return }
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
                        setDrawer(drawerOpen ? !(travelled || flicked) : (travelled || flicked))
                    }
                )
                .allowsHitTesting(false)
            }
        }
    }

    /// Whether the conversation on screen belongs to a bot.
    private var inBotChat: Bool {
        !(store.activeConversation?.botName ?? "").isEmpty
    }

    /// Back out of a bot's conversation to the list it was opened from.
    private func goBackToBots() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
