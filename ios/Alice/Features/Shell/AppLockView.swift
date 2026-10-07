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
    /// The copy in the lock window above sheets leaves asking to this one, so Face ID asks once.
    var asksOnAppear = true
    @State private var asking = false
    /// Asked once per return to the foreground: cancelling Face ID made the scene go inactive and
    /// active again, which asked again, and again.
    @State private var askedThisTime = false

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
            if scenePhase == .background { askedThisTime = false }
            guard asksOnAppear, store.appLocked, scenePhase == .active, !askedThisTime else { return }
            askedThisTime = true
            await unlock()
        }
    }

    private func unlock() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        if await Biometrics.authenticate(reason: "Unlock Alice.") {
            withMotion(.easeOut(duration: 0.25)) { store.appLocked = false }
            onUnlock()
        }
    }
}
