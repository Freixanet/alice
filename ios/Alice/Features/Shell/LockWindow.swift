import SwiftUI
import UIKit

/// The lock in its own window, above every sheet and full-screen cover.
///
/// An `.overlay` on the root view sits under anything presented on top of it: Settings, Memory or a
/// card form stayed visible and usable while Alice was locked, and in the app switcher. A window at
/// alert level covers them all. The overlay stays too, for the instant before this window is up.
struct LockWindowHost: UIViewRepresentable {
    let visible: Bool
    let store: AppStore
    let onUnlock: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(scene: view.window?.windowScene, visible: visible, store: store,
                                   onUnlock: onUnlock)
    }

    @MainActor
    final class Coordinator {
        private var window: UIWindow?

        func update(scene: UIWindowScene?, visible: Bool, store: AppStore, onUnlock: @escaping () -> Void) {
            guard visible, let scene else {
                window?.isHidden = true
                window = nil
                return
            }
            guard window == nil else { return }
            // The overlay under the sheets already asks for Face ID; this one only offers the button.
            let root = AppLockView(onUnlock: onUnlock, asksOnAppear: false)
                .environment(store)
                .preferredColorScheme(store.theme.colorScheme)
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            window.isHidden = false
            self.window = window
        }
    }
}
