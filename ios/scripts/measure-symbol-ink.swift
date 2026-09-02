// Reports where each SF Symbol actually paints inside its layout box.
//
// Two symbols at the same point size do not share a box or an ink size: at
// 16pt the share tray paints 14x17.75pt inside an 18x21 box, the refresh
// cycle 19.75x16 inside 20x18. Laying them out by their boxes therefore
// leaves uneven whitespace between glyphs, which is what makes a row of
// them read as ragged.
//
// `bboxOff` is how far the ink centre sits from the box centre — the optical
// nudge a glyph needs. `massOff` is the alpha-weighted centre, reported for
// comparison; it is the wrong metric for these glyphs (the share tray's
// solid base drags it 1.56pt low) but the right one for a shape like a play
// triangle, so it is worth seeing both.
//
// Run:  swift ios/scripts/measure-symbol-ink.swift
// Feed the numbers into ActionIcon in Features/Chat/MessageRow.swift.

import AppKit

let symbols = [
    "square.on.square", "checkmark", "square.and.arrow.up",
    "speaker.wave.2", "speaker.slash", "arrow.triangle.2.circlepath",
]
let pointSize: CGFloat = 16
let s: CGFloat = 8

for name in symbols {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(
              .init(pointSize: pointSize, weight: .regular, scale: .medium))
    else { print("\(name)\tMISSING"); continue }

    let size = img.size
    let w = Int((size.width * s).rounded()), h = Int((size.height * s).rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.set()
    img.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    NSGraphicsContext.restoreGraphicsState()

    var minX = w, maxX = -1, minY = h, maxY = -1
    var sumX = 0.0, sumY = 0.0, mass = 0.0
    guard let data = rep.bitmapData else { continue }
    let bpr = rep.bytesPerRow
    for y in 0..<h {
        for x in 0..<w {
            let a = Double(data[y * bpr + x * 4 + 3]) / 255.0
            if a > 0.05 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                sumX += Double(x) * a; sumY += Double(y) * a; mass += a
            }
        }
    }
    guard maxX >= 0 else { print("\(name)\tEMPTY"); continue }

    let boxCX = Double(w) / 2, boxCY = Double(h) / 2
    let bboxCX = Double(minX + maxX + 1) / 2, bboxCY = Double(minY + maxY + 1) / 2
    let f = { (v: Double) in (v / Double(s) * 100).rounded() / 100 }
    print("""
    \(name)
      layout   \(f(Double(w)))x\(f(Double(h))) pt
      ink      \(f(Double(maxX - minX + 1)))x\(f(Double(maxY - minY + 1))) pt
      bboxOff  dx \(f(bboxCX - boxCX))  dy \(f(bboxCY - boxCY))
      massOff  dx \(f(sumX / mass - boxCX))  dy \(f(sumY / mass - boxCY))
    """)
}
