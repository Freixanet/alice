#if DEBUG
import UIKit

/// Explicit local diagnostic launch only; never runs in normal app use.
@MainActor
enum ChatScrollEdgeCapture {
    static func schedule(scroll: UIScrollView, band: UIView) {
        if ProcessInfo.processInfo.arguments.contains("--alice-top-edge-capture") {
            scheduleTop(scroll: scroll)
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("--alice-edge-capture") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak scroll, weak band] in
            guard let scroll, let band, let window = band.window else { return }
            let original = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: original.x,
                y: max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height - 160)), animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak scroll, weak band, weak window] in
                guard let scroll, let band, let window else { return }
                let frame = band.convert(band.bounds, to: window)
                DiagnosticsLog.write("chat.edgeFallback.capture band=\(frame) viewport=\(scroll.convert(scroll.bounds, to: window)) offset=\(scroll.contentOffset)")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                if let cg = image.cgImage,
                   let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let rect = CGRect(x: 0, y: max(0, window.bounds.height - 300) * image.scale,
                                      width: window.bounds.width * image.scale, height: 300 * image.scale)
                    if let crop = cg.cropping(to: rect) {
                        try? UIImage(cgImage: crop).pngData()?.write(to: directory.appendingPathComponent("edge-fallback-bottom.png"))
                    }
                }
                scroll.setContentOffset(original, animated: false)
            }
        }
    }

    /// Static rendering audit only: no gestures, prompts or stored-data writes.
    private static func scheduleTop(scroll: UIScrollView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak scroll] in
            guard let scroll, let window = scroll.window,
                  let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            Task { @MainActor [weak scroll, weak window] in
                guard let scroll, let window else { return }
                let original = scroll.contentOffset
                defer { scroll.setContentOffset(original, animated: false) }
                let start = -scroll.adjustedContentInset.top
                for (index, distance) in [CGFloat(0), 36, 120, 240, 0].enumerated() {
                    scroll.setContentOffset(CGPoint(x: original.x, y: start + distance), animated: false)
                    do { try await Task.sleep(for: .milliseconds(650)) }
                    catch { return }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let rect = CGRect(x: 0, y: 0, width: window.bounds.width * image.scale,
                                      height: min(340, window.bounds.height) * image.scale)
                    if let crop = image.cgImage?.cropping(to: rect) {
                        try? UIImage(cgImage: crop).pngData()?.write(to: directory.appendingPathComponent("top-edge-audit-\(index).png"))
                    }
                    DiagnosticsLog.write("chat.topEdgeAudit frame=\(index) offset=\(scroll.contentOffset.y) inset=\(scroll.adjustedContentInset.top) soft=\(scroll.topEdgeEffect.style == .soft) hidden=\(scroll.topEdgeEffect.isHidden) reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled) reduceMotion=\(UIAccessibility.isReduceMotionEnabled)")
                }
            }
        }
    }

}
#endif
