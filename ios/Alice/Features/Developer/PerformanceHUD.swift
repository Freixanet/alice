import SwiftUI

/// A small meter over everything while it is switched on in Developer:
/// frames per second, late frames, and freezes this session — so a screen
/// that stutters shows it as it happens, not afterwards.
struct PerformanceHUD: View {
    static let key = "alice.developer.hud"

    @Environment(\.colorScheme) private var scheme
    private let monitor = HitchMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(monitor.framesPerSecond) fps")
            if monitor.lateFrames > 0 {
                Text("· \(monitor.lateFrames) late")
            }
            if !monitor.stalls.isEmpty {
                Text("· \(monitor.stalls.count) freezes")
                    .foregroundStyle(Palette.danger(scheme))
            }
        }
        .font(.caption2.monospacedDigit().weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var color: Color {
        if !monitor.stalls.isEmpty, let last = monitor.stalls.first, Date().timeIntervalSince(last.at) < 10 {
            return Palette.danger(scheme)
        }
        if monitor.lateFrames > 3 { return Palette.warning(scheme) }
        return Palette.success(scheme)
    }
}
