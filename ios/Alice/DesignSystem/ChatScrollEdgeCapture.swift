#if DEBUG
import UIKit

/// Explicit local diagnostic launch only; never runs in normal app use.
@MainActor
enum ChatScrollEdgeCapture {
    static func schedule(scroll: UIScrollView, band: UIView) {
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
}
#endif
