import SwiftUI

/// What covers Alice while it is locked, and in the app switcher.
///
/// The logo on the brand background, as at launch. Locked, it asks for Face
/// ID on its own the moment it is on screen, with a button to ask again; as
/// a switcher cover it only hides what is behind it.
struct AppLockView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    /// Called once the owner is in.
    var onUnlock: () -> Void = {}
    @State private var asking = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            // The logo exactly where the launch screen draws it, centred; the
            // button hangs below it rather than sharing its column, which
            // pushed the logo up and made it jump on every launch.
            Image("LaunchLogo")
                .ignoresSafeArea()
            VStack {
                Spacer()
                if store.appLocked {
                    Button {
                        Task { await unlock() }
                    } label: {
                        Label("Unlock with \(Biometrics.name)", systemImage: Biometrics.symbol)
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(asking)
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 64)
        }
        .task(id: scenePhase) {
            guard store.appLocked, scenePhase == .active else { return }
            await unlock()
        }
    }

    private func unlock() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        if await Biometrics.authenticate(reason: "Unlock Alice.") {
            withAnimation(.easeOut(duration: 0.25)) { store.appLocked = false }
            onUnlock()
        }
    }
}
