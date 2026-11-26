import AppKit
import QuartzCore
import SwiftUI

/// The album cover on a plain disc with a hole in the middle. The disc turns in Core Animation (the
/// render server does the work, not the app): it speeds up from rest with an ease-in, then spins at a
/// constant speed, and slows down to rest when playback pauses or stops. Every change of speed starts
/// from the angle and speed the disc has at that moment, so nothing jumps.
/// Hover shading, the "Change CD" label, the small shift to the left and the shadow are layers of the
/// same view, so they move and fade as one piece with the disc.
struct DiscView: NSViewRepresentable {
    var cover: CGImage
    var spinning: Bool
    var shaded = false
    var label = "Change CD"

    func makeNSView(context: Context) -> DiscNSView { DiscNSView() }

    func updateNSView(_ v: DiscNSView, context: Context) {
        v.setCover(cover)
        v.setSpinning(spinning)
        v.setShaded(shaded, label: label)
    }
}

/// A disc: the circle with its centre hole (even-odd), for the empty frosted disc, hover shade and hit test.
struct DiscShape: Shape {
    func path(in r: CGRect) -> Path {
        let side = min(r.width, r.height)
        let c = CGPoint(x: r.midX, y: r.midY)
        let h = side * Face.hole
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side))
        p.addEllipse(in: CGRect(x: c.x - h, y: c.y - h, width: 2 * h, height: 2 * h))
        return p
    }
}

final class DiscNSView: NSView {
    private let shadowLayer = CALayer()
    private let disc = CALayer()
    private let shade = CAShapeLayer()
    private let labelLayer = CALayer()
    private var shaded = false
    private var labelText = ""
    /// Shift to the left while shaded, points.
    static let shift: CGFloat = 16
    private var cover: CGImage?
    private var faceSize: CGFloat = 0
    private var hasFace = false

    /// Full speed, rad/s (negative: clockwise). One turn every 2.2 s.
    static let speed: Double = -2 * .pi / 2.2
    /// Time to reach full speed from rest (and to stop from full speed).
    static let ramp: Double = 1.6

    // The current speed ramp: speed goes linearly from v0 to v1 between t0 and t0 + d.
    private var v0 = 0.0, v1 = 0.0, t0 = 0.0, d = 0.0
    private var spinning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        for l in [shadowLayer, disc, shade, labelLayer] { layer?.addSublayer(l) }
        disc.contentsGravity = .resizeAspect
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        shade.fillRule = .evenOdd
        shade.fillColor = NSColor(white: 0, alpha: 0.45).cgColor
        shade.opacity = 0
        labelLayer.opacity = 0
        labelLayer.contentsGravity = .center
    }

    /// Darkens the disc, shows the label and moves everything a little to the left (or back).
    func setShaded(_ on: Bool, label: String) {
        if label != labelText { labelText = label; renderLabel() }
        guard on != shaded else { return }
        shaded = on
        let dur = 0.28
        let timing = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        CATransaction.setAnimationTimingFunction(timing)
        shade.opacity = on ? 1 : 0
        labelLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        // The whole stack moves together: one transform on the parent of every layer.
        guard let root = layer else { return }
        let from = (root.presentation()?.sublayerTransform ?? root.sublayerTransform)
        let to = on ? CATransform3DMakeTranslation(-Self.shift, 0, 0) : CATransform3DIdentity
        let a = CABasicAnimation(keyPath: "sublayerTransform")
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: to)
        a.duration = dur
        a.timingFunction = timing
        root.sublayerTransform = to
        root.add(a, forKey: "shift")
    }

    private func renderLabel() {
        let scale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text = NSAttributedString(string: labelText, attributes: [.font: font, .foregroundColor: NSColor.white])
        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium).applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        let ts = text.size()
        let ss = symbol?.size ?? .zero
        let size = NSSize(width: ceil(max(ts.width, ss.width)) + 4, height: ceil(ss.height + 6 + ts.height))
        let img = NSImage(size: size, flipped: false) { _ in
            symbol?.draw(in: NSRect(x: (size.width - ss.width) / 2, y: ts.height + 6, width: ss.width, height: ss.height))
            text.draw(at: NSPoint(x: (size.width - ts.width) / 2, y: 0))
            return true
        }
        labelLayer.contents = img.layerContents(forContentsScale: scale)
        labelLayer.contentsScale = scale
        labelLayer.bounds = CGRect(origin: .zero, size: size)
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let full = CGRect(x: 0, y: 0, width: side, height: side)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for l in [shadowLayer, disc, shade] as [CALayer] {
            l.bounds = full
            l.position = centre
        }
        let ring = CGMutablePath()
        ring.addEllipse(in: full)
        let h = side * Face.hole
        ring.addEllipse(in: CGRect(x: side / 2 - h, y: side / 2 - h, width: 2 * h, height: 2 * h))
        shade.path = ring
        shadowLayer.shadowPath = ring
        // Below the hole, as before.
        labelLayer.position = CGPoint(x: centre.x, y: centre.y - side * 0.21)
        CATransaction.commit()
        if abs(side - faceSize) > 1 || !hasFace { renderFace(side) }
    }

    func setCover(_ c: CGImage) {
        guard c !== cover else { return }
        cover = c
        hasFace = false
        needsLayout = true
    }

    private func renderFace(_ side: CGFloat) {
        guard side > 4, let cover else { return }
        faceSize = side
        hasFace = true
        let scale = window?.backingScaleFactor ?? 2
        let t0 = CACurrentMediaTime()
        disc.contents = Face.render(cover: cover, pixels: Int(side * scale))
        MainActor.assumeIsolated { Snapshots.log(String(format: "face %.1f ms (%dx%d cover)", (CACurrentMediaTime() - t0) * 1000, cover.width, cover.height)) }
        disc.contentsScale = scale
    }

    // MARK: spin

    private func speed(at t: Double) -> Double {
        if d <= 0 || t >= t0 + d { return v1 }
        if t <= t0 { return v0 }
        return v0 + (v1 - v0) * (t - t0) / d
    }

    func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        let now = CACurrentMediaTime()
        let vNow = speed(at: now)
        let target = on ? Self.speed : 0
        let angle = (disc.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double)
            ?? (disc.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let dur = Self.ramp * abs(target - vNow) / abs(Self.speed)
        let dist = (vNow + target) / 2 * dur
        v0 = vNow; v1 = target; t0 = now; d = dur

        disc.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.setValue(angle + (on ? 0 : dist), forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        if dur > 0.001 {
            // Speed changes linearly, so the angle follows a parabola: a cubic Bézier with these
            // control points is exactly that, with start slope v0·d/dist and end slope v1·d/dist.
            let s0 = vNow * dur / dist, s1 = target * dur / dist
            let ramp = CABasicAnimation(keyPath: "transform.rotation.z")
            ramp.fromValue = angle
            ramp.toValue = angle + dist
            ramp.duration = dur
            ramp.beginTime = disc.convertTime(now, from: nil)
            ramp.timingFunction = CAMediaTimingFunction(controlPoints: 1 / 3, Float(s0 / 3), 2 / 3, Float(1 - s1 / 3))
            ramp.fillMode = .forwards
            ramp.isRemovedOnCompletion = false
            disc.add(ramp, forKey: "ramp")
        }
        if on {
            // Then a constant spin, taking over exactly where the ramp ends, at the same speed.
            let a = angle + (dur > 0.001 ? dist : 0)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = a
            spin.toValue = a + 2 * .pi * (Self.speed < 0 ? -1 : 1)
            spin.duration = 2 * .pi / abs(Self.speed)
            spin.repeatCount = .infinity
            spin.beginTime = disc.convertTime(now + dur, from: nil)
            disc.add(spin, forKey: "spin")
        }
    }
}

/// The disc face: the cover, aspect fill, cut to a circle with the centre hole. Drawn once per size.
enum Face {
    /// Hole radius as a fraction of the diameter (a CD: Ø15 mm of Ø120 mm).
    static let hole: CGFloat = 0.0625

    static func render(cover: CGImage, pixels px: Int) -> CGImage? {
        let s = CGFloat(px)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let h = s * hole
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
        p.addEllipse(in: CGRect(x: s / 2 - h, y: s / 2 - h, width: 2 * h, height: 2 * h))
        ctx.addPath(p)
        ctx.clip(using: .evenOdd)
        let w = CGFloat(cover.width), ht = CGFloat(cover.height)
        let k = max(s / w, s / ht)
        ctx.draw(cover, in: CGRect(x: (s - w * k) / 2, y: (s - ht * k) / 2, width: w * k, height: ht * k))
        return ctx.makeImage()
    }
}
