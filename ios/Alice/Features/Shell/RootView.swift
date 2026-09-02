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

                ChatScreen(onOpenDrawer: { setDrawer(true) })
                    .overlay {
                        // Grows with the gesture rather than appearing at the end,
                        // so the conversation hands over its prominence gradually.
                        Color.black.opacity(0.28 * progress)
                            .ignoresSafeArea()
                            // Only swallows touches once the drawer is really
                            // open, so a half-swipe never blocks the chat.
                            .allowsHitTesting(drawerOpen)
                            .onTapGesture { setDrawer(false) }
                    }
                    // Rounded to the display's own radius: once it has moved, its
                    // left corners are out in the middle of the screen, and square
                    // ones there would give away that this is a flat layer rather
                    // than the phone's surface sliding aside.
                    .clipShape(.rect(cornerRadius: displayCornerRadius))
                    .offset(x: offset)
            }
            // Both layers have to reach the physical edges: the drawer so it fills
            // the display behind, and the conversation so its rounded corners land
            // on the bezel rather than being cut at the status bar. The screens
            // inside still take their insets from the window, so nothing moves.
            .ignoresSafeArea()
            .background(Palette.background(scheme))
            .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: drawerOpen)
            // The drawer answers a sideways swipe from anywhere, not just from a
            // strip at the edge. `DrawerPan` only claims a drag that starts out
            // sideways, so scrolling the conversation is untouched.
            .overlay {
                DrawerPan(
                    shouldBegin: { velocity in
                        // Sideways enough to be meant sideways, and pointing the
                        // way the drawer can actually move from here.
                        guard abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
                        return drawerOpen ? velocity.x < 0 : velocity.x > 0
                    },
                    onChange: { translation in
                        drag = drawerOpen ? min(0, translation) : max(0, translation)
                    },
                    onEnd: { translation, predicted in
                        let travelled = abs(translation) > drawerWidth * 0.3
                        let flicked = abs(predicted) > 120
                        drag = 0
                        setDrawer(drawerOpen ? !(travelled || flicked) : (travelled || flicked))
                    }
                )
                .allowsHitTesting(false)
            }
        }
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
