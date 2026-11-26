// Built from the suite's shared icon design system (IconKit: Core + Symbols/CD.swift), as a
// self-contained copy so this repository builds its icon on its own.
// Usage: swift make-icon.swift <folder>  →  <folder>/AppIcon.iconset (+ icon-preview.png)

import Cocoa

// ─────────────────────────────────────────────────────────────────────────────
// Selfmade Utilities — icon design system (shared by all 10 apps).
//
// The source of truth lives in IconKit/ at the suite root: Core.swift (this file) plus one
// Symbols/<App>.swift per app. IconKit/build.sh compiles them, regenerates every app's
// AppIcon.icns + icon-preview.png, writes the contact sheet, and refreshes each app's own
// make-icon.swift as a self-contained copy (Core + that app's symbol), because every app is a
// separate repository. Edit the files here, never the generated copies.
//
// Coordinates: 1024 canvas, squircle 824×824 inset 100. Symbols are drawn on a 16×16 grid laid
// over the squircle (y up). Every symbol is fitted automatically into the same safe box
// (Scene's: 2.8…13.2 on the grid, 65 % of the squircle); strokes keep their weight while the
// geometry moves, so line weights match across the suite.
// ─────────────────────────────────────────────────────────────────────────────

enum DS {
    static let canvas: CGFloat = 1024
    static let inset: CGFloat = 100
    static let side: CGFloat = 824
    static var u: CGFloat { side / 16 }
    /// Safe box on the 16-grid, taken from Scene's window layout.
    static let safeMin: CGFloat = 2.8, safeMax: CGFloat = 13.2
    static var safeSize: CGFloat { safeMax - safeMin }
    /// Clear gap (grid units) left between glass parts that would otherwise touch or overlap.
    static let gap: CGFloat = 0.16
    /// Stroke weights (grid units), the same in every icon.
    static let strokeBold: CGFloat = 0.95
    static let strokeMid: CGFloat = 0.62
    static let strokeThin: CGFloat = 0.34
    /// Background ramp, applied to each app's OKLCH base colour: top / middle / bottom.
    static let rampL: [CGFloat] = [+0.055, 0, -0.06]
    static let rampC: [CGFloat] = [0.86, 1, 1.06]
    static let grainSeed: UInt64 = 0x5CE11E
}

// MARK: - Colour

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

/// OKLCH → sRGB, pulling chroma in until the colour fits the gamut.
func oklch(_ L: CGFloat, _ C: CGFloat, _ H: CGFloat) -> CGColor {
    var c = C
    while true {
        let h = H * .pi / 180, a = c * cos(h), b = c * sin(h)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let lin = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                   -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                   -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
        if lin.allSatisfy({ $0 >= -0.001 && $0 <= 1.001 }) || c < 0.002 {
            let e = lin.map { v -> CGFloat in
                let x = min(1, max(0, v))
                return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            }
            return CGColor(srgbRed: e[0], green: e[1], blue: e[2], alpha: 1)
        }
        c -= 0.002
    }
}

/// An app's background: one OKLCH base colour run through the shared ramp.
struct Palette {
    var L: CGFloat, C: CGFloat, H: CGFloat
    var colors: [CGColor] { (0..<3).map { oklch(L + DS.rampL[$0], C * DS.rampC[$0], H) } }
}

/// Glass tones: one fill pair (top, bottom) and one shadow strength each, shared by all icons.
enum Tone {
    case primary, secondary, dim, bright
    var fill: (CGColor, CGColor) {
        switch self {
        case .primary: return (white(0.62), white(0.50))
        case .secondary: return (white(0.38), white(0.30))
        case .dim: return (white(0.18), white(0.13))
        case .bright: return (white(0.86), white(0.76))
        }
    }
    var shadow: CGFloat {
        switch self {
        case .primary: return 0.45
        case .secondary: return 0.38
        case .dim: return 0.2
        case .bright: return 0.3
        }
    }
}

// MARK: - Geometry

/// One glass part: a single, already unioned outline in canvas space, and its tone.
struct Layer { var path: CGPath; var tone: Tone }

/// Maps design coordinates (the 16-grid) onto the canvas, with the fit scale and offset.
final class Geo {
    var k: CGFloat = 1, ox: CGFloat = 0, oy: CGFloat = 0
    /// False at 16–32 px: symbols may drop details that would turn to mush.
    var detail = true
    var u: CGFloat { DS.u }
    var T: CGAffineTransform {
        CGAffineTransform(translationX: DS.inset + ox * u, y: DS.inset + oy * u).scaledBy(x: k * u, y: k * u)
    }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(T) }
    /// A filled design-space shape, moved onto the canvas (it scales with the fit).
    func fill(_ p: CGPath) -> CGPath { var t = T; return p.copy(using: &t)! }
    /// A design-space centre line stroked on the canvas: the line weight does not scale with the fit.
    func stroke(_ p: CGPath, _ w: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) -> CGPath {
        fill(p).copy(strokingWithWidth: w * u, lineCap: cap, lineJoin: join, miterLimit: 10)
    }
    /// A filled shape whose corners are rounded by `r` (grid units, not scaled): fill ∪ its outline.
    func rounded(_ p: CGPath, _ r: CGFloat) -> CGPath { fill(p).union(stroke(p, 2 * r)) }
}

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
}
func polyline(_ pts: [(CGFloat, CGFloat)], closed: Bool = false) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: pts.map { CGPoint(x: $0.0, y: $0.1) })
    if closed { p.closeSubpath() }
    return p
}
func unionAll(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1) }
}

struct Icon {
    var name: String
    var palette: Palette
    /// Optical size inside the safe box (1 = fills it on its long side).
    var optical: CGFloat = 1
    /// Optical vertical nudge, grid units (positive = up).
    var dy: CGFloat = 0
    var build: (Geo) -> [Layer]
}

// MARK: - Fit

func bounds(_ layers: [Layer]) -> CGRect {
    layers.map { $0.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
}

/// Fits the symbol into the safe box: scales the geometry (not the strokes) until its long side
/// is `safeSize × optical`, then centres it.
func fitted(_ icon: Icon) -> Geo {
    let g = Geo()
    let target = DS.safeSize * icon.optical
    for _ in 0..<8 {
        let b = bounds(icon.build(g))
        let size = max(b.width, b.height) / g.u
        g.k *= target / size
        let b2 = bounds(icon.build(g))
        g.ox += 8 - (b2.midX - DS.inset) / g.u
        g.oy += 8 + icon.dy - (b2.midY - DS.inset) / g.u
    }
    return g
}

/// The symbol's extent on the grid after fitting (for the safe-area report).
func extent(_ icon: Icon) -> CGRect {
    let b = bounds(icon.build(fitted(icon)))
    return CGRect(x: (b.minX - DS.inset) / DS.u, y: (b.minY - DS.inset) / DS.u, width: b.width / DS.u, height: b.height / DS.u)
}

/// Zero overlap: every part loses whatever lies under the parts drawn above it, plus a thin gap.
func separated(_ layers: [Layer]) -> [Layer] {
    var out = layers
    let gap = DS.gap * DS.u
    for i in out.indices {
        for j in layers.indices where j > i {
            let up = layers[j].path
            guard up.boundingBoxOfPath.insetBy(dx: -gap * 2, dy: -gap * 2).intersects(out[i].path.boundingBoxOfPath) else { continue }
            let halo = up.union(up.copy(strokingWithWidth: gap * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
            out[i].path = out[i].path.subtracting(halo)
        }
    }
    return out
}

// MARK: - Drawing

/// macOS icon shape: rectangle with continuous corners, radius ≈ 22.5 %.
func squirclePath(_ r: CGRect) -> CGPath {
    let R = min(r.width, r.height) * 0.225
    let p = CGMutablePath()
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    for (i, (c, d1, d2)) in corners.enumerated() {
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x - d1.dx * a * R + d2.dx * b * R, y: c.y - d1.dy * a * R + d2.dy * b * R)
        }
        if i == 0 { p.move(to: pt(1.52866483, 0)) } else { p.addLine(to: pt(1.52866483, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0.02065399))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905607), control2: pt(0.16905607, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0.02065399, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func render(_ icon: Icon, px: Int, fit: Geo? = nil) -> CGImage {
    let sc = CGFloat(px) / DS.canvas
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: sc, y: sc)
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
    }
    // Shadow offsets and blurs are in device pixels, so they are scaled by hand.
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * sc), blur: blur * sc, color: color)
    }

    let s = DS.canvas, m = DS.inset, side = DS.side, u = DS.u
    let rect = CGRect(x: m, y: m, width: side, height: side)
    let squircle = squirclePath(rect)

    // Icon drop shadow: wide and faint + tight contact shadow.
    for (off, blur, a) in [(0.014, 0.04, 0.28), (0.003, 0.006, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        shadow(s * off, s * blur, rgb(0, 0, 0, a))
        ctx.addPath(squircle); ctx.setFillColor(rgb(90, 92, 98)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Background: the app colour through the shared vertical ramp, light from above.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad(icon.palette.colors, [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // Soft top sheen, the same on every icon.
    ctx.drawLinearGradient(grad([white(0.10), white(0)], [0, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.maxY - side * 0.45), options: [])
    ctx.restoreGState()

    /// Frosted glass: soft drop shadow, vertical gradient body, light rim on top, faint shade below.
    func glass(_ path: CGPath, _ tone: Tone) {
        let box = path.boundingBoxOfPath
        let (top, bottom) = tone.fill
        for (off, blur, a) in [(0.16, 0.22, tone.shadow), (0.5, 1.0, tone.shadow * 0.65)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            shadow(u * off, u * blur, rgb(20, 20, 26, a * 0.55))
            ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
            ctx.restoreGState()
        }
        // Re-draw the background under the glass so the body is truly translucent (the shadow fill
        // above would otherwise darken it), then the glass body on top.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(grad(icon.palette.colors, [0, 0.5, 1]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        ctx.drawLinearGradient(grad([white(0.10), white(0)], [0, 1]),
                               start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.maxY - side * 0.45), options: [])
        ctx.drawLinearGradient(grad([top, bottom], [0, 1]),
                               start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        // Rim: a band of constant width inside the outline, lit where the edge faces up and shaded
        // where it faces down. Each step paints the part of the band that leaves the shape when it is
        // moved up (or down), so flat tops collect every step and vertical sides none.
        let lw = max(1 / sc, u * 0.085)
        ctx.addPath(path); ctx.setLineWidth(lw * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
        func rim(up: Bool, alpha: CGFloat, _ color: (CGFloat) -> CGColor) {
            let steps = 10
            let a = 1 - pow(1 - alpha, 1 / CGFloat(steps))
            for k in 1...steps {
                let shift = lw * 0.45 * CGFloat(k) * (up ? -1 : 1)
                let band = CGMutablePath()
                band.addRect(box.insetBy(dx: -u * 2, dy: -u * 2))
                band.addPath(path, transform: CGAffineTransform(translationX: 0, y: shift))
                ctx.addPath(band); ctx.setFillColor(color(a)); ctx.fillPath(using: .evenOdd)
            }
        }
        ctx.setFillColor(white(0.3)); ctx.fill(box.insetBy(dx: -u, dy: -u))
        rim(up: true, alpha: 0.8) { white($0) }
        rim(up: false, alpha: 0.2) { rgb(0, 0, 0, $0) }
        ctx.restoreGState()
    }

    let g = fit ?? fitted(icon)
    g.detail = px >= 64
    let layers = separated(icon.build(g))
    // Bottom to top; each part repaints the background inside itself, so it stays translucent.
    for l in layers { glass(l.path, l.tone) }

    // Icon rim: specular light along the top edge, shade at the bottom.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.addPath(squircle); ctx.setLineWidth(max(1 / sc, s * 0.006) * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([white(0.6), white(0), rgb(0, 0, 0, 0), rgb(0, 0, 0, 0.32)], [0, 0.3, 0.75, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Grain: the same faint texture and seed on every icon.
    if px >= 128 {
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        var seed = DS.grainSeed
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        let dot = max(1, CGFloat(px) / 512) / sc
        for _ in 0..<(px * px / 6) {
            let v = rnd()
            ctx.setFillColor(v > 0.5 ? white(0.016) : rgb(0, 0, 0, 0.016))
            ctx.fill(CGRect(x: rect.minX + rnd() * side, y: rect.minY + rnd() * side, width: dot, height: dot))
        }
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func png(_ img: CGImage) -> Data { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])! }

/// Writes <folder>/AppIcon.iconset and <folder>/icon-preview.png (512 px).
func writeIconset(_ icon: Icon, to folder: String) {
    let set = folder + "/AppIcon.iconset"
    try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
    let g = fitted(icon)
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        try! png(render(icon, px: px, fit: g)).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
    }
    try! png(render(icon, px: 512, fit: g)).write(to: URL(fileURLWithPath: "\(folder)/icon-preview.png"))
}

import Cocoa

import Cocoa

// CD: a compact disc on dark graphite, almost black: the disc with its hub cut out and the clear
// hub ring around the centre hole.
let iconCD = Icon(name: "CD", palette: Palette(L: 0.30, C: 0.006, H: 260)) { g in
    let disc = g.fill(circle(8, 8, 5.2)).subtracting(g.fill(circle(8, 8, 2.05)))
    let hub = g.fill(circle(8, 8, 1.75)).subtracting(g.fill(circle(8, 8, 0.72)))
    return [Layer(path: disc, tone: .primary), Layer(path: hub, tone: .secondary)]
}

writeIconset(iconCD, to: CommandLine.arguments[1])
