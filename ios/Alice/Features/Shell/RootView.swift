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

            // A thin strip owns the open gesture. Putting the drag on the whole
            // screen fought every scroll view underneath it.
            if !drawerOpen {
                Color.clear
                    .frame(width: 20)
                    .contentShape(.rect)
                    .gesture(edgeDrag)
                    .ignoresSafeArea()
            }
        }
        .background(Palette.background(scheme))
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: drawerOpen)
        .gesture(drawerOpen ? closeDrag : nil)
    }

    private var offset: CGFloat {
        min(max((drawerOpen ? drawerWidth : 0) + drag, 0), drawerWidth)
    }

    private var progress: CGFloat { offset / drawerWidth }

    private var edgeDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { drag = max(0, $0.translation.width) }
            .onEnded { value in
                let flick = value.predictedEndTranslation.width > 120
                let far = drag > drawerWidth * 0.3
                drag = 0
                setDrawer(flick || far)
            }
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { drag = min(0, $0.translation.width) }
            .onEnded { value in
                let flick = value.predictedEndTranslation.width < -120
                let far = drag < -drawerWidth * 0.3
                drag = 0
                setDrawer(!(flick || far))
            }
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
