import SwiftUI

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
        ZStack(alignment: .leading) {
            ChatScreen(onOpenDrawer: { setDrawer(true) })
                .offset(x: offset * 0.28)
                .overlay {
                    if offset > 0 {
                        Color.black.opacity(0.3 * progress)
                            .ignoresSafeArea()
                            // Only swallows touches once the drawer is really
                            // open, so a half-swipe never blocks the chat.
                            .allowsHitTesting(drawerOpen)
                            .onTapGesture { setDrawer(false) }
                    }
                }

            Sidebar(width: drawerWidth, onDismiss: { setDrawer(false) })
                .frame(width: drawerWidth)
                .offset(x: offset - drawerWidth)
        }
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

    private var offset: CGFloat {
        min(max((drawerOpen ? drawerWidth : 0) + drag, 0), drawerWidth)
    }

    private var progress: CGFloat { offset / drawerWidth }

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
