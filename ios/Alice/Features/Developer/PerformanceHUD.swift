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

/// The meter where the person left it. It starts centred under the composer
/// and follows a finger anywhere on screen; the spot is kept between launches,
/// and a double tap sends it home.
struct MovablePerformanceHUD: View {
    static let offsetKey = "alice.developer.hud.offset"

    /// The space it may move in, and the gap it keeps from the bottom edge
    /// when at home.
    let bounds: CGSize
    let topInset: CGFloat
    let bottomPadding: CGFloat

    @AppStorage(offsetKey) private var stored = ""
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var size: CGSize = .zero
    @State private var loaded = false
    @State private var resets = 0

    var body: some View {
        PerformanceHUD()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .padding(.bottom, bottomPadding)
            .offset(offset)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? offset
                        if dragStart == nil { dragStart = start }
                        offset = clamped(CGSize(width: start.width + value.translation.width,
                                                height: start.height + value.translation.height))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        stored = "\(Int(offset.width)),\(Int(offset.height))"
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy(duration: 0.3)) { offset = .zero }
                stored = ""
                resets += 1
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let parts = stored.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { offset = CGSize(width: parts[0], height: parts[1]) }
            }
            // The screen turned or changed size: keep it on it.
            .onChange(of: bounds) { offset = clamped(offset) }
            .sensoryFeedback(.selection, trigger: resets)
    }

    /// Anywhere the whole meter stays visible, below the status bar.
    private func clamped(_ proposed: CGSize) -> CGSize {
        guard size != .zero, bounds != .zero else { return proposed }
        let margin: CGFloat = 8
        let horizontal = max((bounds.width - size.width) / 2 - margin, 0)
        let up = max(bounds.height - size.height - bottomPadding - topInset - margin, 0)
        return CGSize(
            width: min(max(proposed.width, -horizontal), horizontal),
            height: min(max(proposed.height, -up), bottomPadding - margin / 2)
        )
    }
}
