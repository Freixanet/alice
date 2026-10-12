import SwiftUI

/// Explanation only. No legacy checkout button, biometric approval or PSP call.
struct SecureRunnerStatusCard: View {
    @Environment(\.colorScheme) private var scheme
    let status: SecureRunnerDisplayStatus
    let language: ChatLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(status.title(language), systemImage: status == .confirmed ? "checkmark.shield" : "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(status.explanation(language))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.card(scheme), in: .rect(cornerRadius: 24))
        .accessibilityIdentifier("secureRunner.status.\(status.rawValue)")
    }
}
