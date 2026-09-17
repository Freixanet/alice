import SwiftUI

/// The launch screen, carried over into the app and let go of.
///
/// iOS centres the logo on the brand background; home draws its own higher,
/// above its greeting. Neither a cut (the logo seen jumping up) nor a glide
/// between the two (a diagonal drift) read well. This dissolves: the launch
/// logo fades and settles where it is while the background clears, and home's
/// logo only comes in once that has gone, so the eye meets one logo leaving
/// and then another arriving, never the same one moving. It adds no waiting.
struct LaunchCurtain: View {
    @Environment(AppStore.self) private var store
    @State private var leaving = false
    @State private var gone = false

    var body: some View {
        if !gone {
            ZStack {
                Color("LaunchBackground")
                    .opacity(leaving ? 0 : 1)
                    .animation(.easeInOut(duration: 0.4), value: leaving)
                Image("LaunchLogo")
                    .scaleEffect(leaving ? 0.9 : 1)
                    .opacity(leaving ? 0 : 1)
                    .animation(.easeIn(duration: 0.22), value: leaving)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                leaving = true
                try? await Task.sleep(for: .milliseconds(180))
                store.launchRevealed = true
                try? await Task.sleep(for: .milliseconds(260))
                gone = true
            }
        }
    }
}
