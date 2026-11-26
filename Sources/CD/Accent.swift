import AppKit
import SwiftUI

/// The app's accent colour, taken from the album cover.
///
/// The cover's most characteristic colour (the strongest hue, weighted by how much of the cover it
/// covers and how vivid it is) is adjusted twice, once for light mode and once for dark mode:
/// - its saturation is capped, so a neon cover doesn't give a neon interface;
/// - its lightness is moved, keeping the hue, until it has at least 4.5:1 contrast with the window
///   background (WCAG AA for text), so the playing-track icon and the slider read on any cover.
/// Covers with no real colour (black and white, greys) keep the system accent colour.
struct Accent: Equatable {
    let light: NSColor
    let dark: NSColor

    static let minimumContrast = 4.5
    /// The hardest background the accent sits on, per appearance: the queue panel, a little darker than
    /// the light window and a little lighter than the dark one.
    static let lightBackground = RGB(0.86, 0.86, 0.86)
    static let darkBackground = RGB(0.22, 0.22, 0.22)

    var color: Color {
        let l = light, d = dark
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
        })
    }

    static func == (a: Accent, b: Accent) -> Bool { a.light == b.light && a.dark == b.dark }

    /// nil when the cover has no colour worth using.
    static func from(_ image: CGImage?) -> Accent? {
        guard let image, let base = dominant(image) else { return nil }
        var hsl = base.hsl
        // Not neon, and not so grey that it no longer reads as the cover's colour.
        hsl.s = min(max(hsl.s, 0.32), 0.78)
        return Accent(light: fit(hsl, on: lightBackground, darker: true).ns,
                      dark: fit(hsl, on: darkBackground, darker: false).ns)
    }

    /// Moves the lightness (darker on a light window, lighter on a dark one) until the contrast is enough,
    /// as little as needed.
    static func fit(_ c: HSL, on bg: RGB, darker: Bool) -> RGB {
        var hsl = c
        // Start from a lightness that suits the appearance, then walk until the contrast holds.
        // Never near black on a light window, never near white on a dark one: the accent keeps its colour.
        hsl.l = darker ? min(max(hsl.l, 0.34), 0.55) : min(max(hsl.l, 0.55), 0.74)
        for _ in 0..<60 {
            if hsl.rgb.contrast(with: bg) >= minimumContrast { break }
            hsl.l = darker ? max(0, hsl.l - 0.01) : min(1, hsl.l + 0.01)
        }
        return hsl.rgb
    }

    /// The cover's characteristic colour: hues in 24 bins, each pixel weighted by saturation and by not
    /// being too dark or too pale; the winning bin's average colour.
    static func dominant(_ image: CGImage) -> RGB? {
        let n = 32
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        var weight = [Double](repeating: 0, count: 24)
        var sum = [RGB](repeating: RGB(0, 0, 0), count: 24)
        var total = 0.0
        for i in 0..<(n * n) {
            let c = RGB(Double(px[4 * i]) / 255, Double(px[4 * i + 1]) / 255, Double(px[4 * i + 2]) / 255)
            let h = c.hsl
            total += 1
            // Vivid, mid-light pixels count most; greys, near-blacks and near-whites little. A muted cover
            // still has a colour: it counts too, just less.
            let w = h.s * h.s * max(0.05, 1 - abs(h.l - 0.5) * 1.8)
            guard h.s > 0.06, w > 0.0005 else { continue }
            let bin = min(23, Int(h.h * 24))
            weight[bin] += w
            sum[bin] = RGB(sum[bin].r + c.r * w, sum[bin].g + c.g * w, sum[bin].b + c.b * w)
        }
        // Neighbouring bins belong together (a red cover spans two or three of them).
        var best = 0, bestW = 0.0
        for b in 0..<24 {
            let w = weight[(b + 23) % 24] * 0.5 + weight[b] + weight[(b + 1) % 24] * 0.5
            if w > bestW { bestW = w; best = b }
        }
        // Only a cover with practically no colour (greys, black, white) keeps the system accent.
        guard bestW / total > 0.002, weight[best] > 0 else { return nil }
        let w = weight[best]
        return RGB(sum[best].r / w, sum[best].g / w, sum[best].b / w)
    }
}

struct RGB: Equatable {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// WCAG relative luminance.
    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    var hsl: HSL {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return HSL(h: 0, s: 0, l: l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return HSL(h: h, s: s, l: l)
    }
}

struct HSL {
    var h, s, l: Double
    var rgb: RGB {
        guard s > 0 else { return RGB(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(f(h + 1.0 / 3), f(h), f(h - 1.0 / 3))
    }
}
