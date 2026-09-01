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
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ChatScreen(onOpenDrawer: openDrawer)
                    .disabled(drawerOpen)
                    .overlay {
                        if drawerOpen {
                            // Tapping the conversation closes the drawer, the
                            // way it does everywhere else this pattern is used.
                            Color.black.opacity(0.28 * progress)
                                .ignoresSafeArea()
                                .onTapGesture { closeDrawer() }
                        }
                    }
                    .offset(x: offset * 0.35)

                Sidebar(width: drawerWidth, onDismiss: closeDrawer)
                    .frame(width: drawerWidth)
                    .offset(x: offset - drawerWidth)
            }
            .background(Palette.background(scheme))
            .gesture(edgeDrag(in: geometry.size))
            .animation(.interactiveSpring(response: 0.32, dampingFraction: 0.86), value: drawerOpen)
        }
    }

    private var offset: CGFloat {
        let base: CGFloat = drawerOpen ? drawerWidth : 0
        return min(max(base + drag, 0), drawerWidth)
    }

    private var progress: CGFloat { offset / drawerWidth }

    /// Swipe from the left edge to open, and anywhere to close. The threshold is
    /// a third of the width so a hesitant drag settles rather than sticking.
    private func edgeDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if drawerOpen {
                    drag = min(0, value.translation.width)
                } else if value.startLocation.x < 28 {
                    drag = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                let shouldOpen = offset > drawerWidth / 3
                    || value.predictedEndTranslation.width > drawerWidth / 2
                drag = 0
                drawerOpen = drawerOpen ? offset > drawerWidth / 2 : shouldOpen
            }
    }

    private func openDrawer() {
        drag = 0
        drawerOpen = true
    }

    private func closeDrawer() {
        drag = 0
        drawerOpen = false
    }
}
