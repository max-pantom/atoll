// Average / vibrant colour of album artwork, used to tint the waveform and scrubber.
import SwiftUI
import AppKit

enum ArtworkColor {
    /// Saturation-weighted average, lifted so it stays legible on pure black.
    static func vibrant(from image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .white }

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in 0..<(side * side) {
            let pr = Double(pixels[i * 4]) / 255, pg = Double(pixels[i * 4 + 1]) / 255, pb = Double(pixels[i * 4 + 2]) / 255
            let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            let w = 0.05 + sat * sat * mx            // favour saturated, bright pixels
            r += pr * w; g += pg * w; b += pb * w; total += w
        }
        guard total > 0 else { return .white }
        let avg = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let lifted = NSColor(hue: h, saturation: min(1, s * 1.15), brightness: max(0.75, v), alpha: 1)
        return Color(nsColor: lifted)
    }
}
