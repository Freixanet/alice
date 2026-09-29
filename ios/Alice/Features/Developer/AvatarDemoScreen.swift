import SwiftUI

/// Developer › Alice working avatar: the header avatar at rest and at work, side by side and
/// switchable, to see the animation whenever one likes.
struct AvatarDemoScreen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var working = true

    var body: some View {
        List {
            Section {
                AliceAvatar(size: 140, working: working)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                Toggle("Working", isOn: $working.animation())
            } footer: {
                Text(reduceMotion
                     ? "Reduce Motion is on, so the avatar stays still."
                     : "The chat header plays this while Alice answers or an errand is working.")
            }
            Section("Sizes") {
                HStack(spacing: 24) {
                    AliceAvatar(size: 48, working: true)
                    AliceAvatar(size: 72, working: true)
                    AliceAvatar(size: 96, working: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background(scheme))
        .navigationTitle("Alice working")
        .navigationBarTitleDisplayMode(.inline)
    }
}
