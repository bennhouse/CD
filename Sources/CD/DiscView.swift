import AppKit
import QuartzCore
import SwiftUI

/// The album cover on a plain disc with a hole in the middle. The disc turns in Core Animation (the
/// render server does the work, not the app): it speeds up from rest with an ease-in, then spins at a
/// constant speed, and slows down to rest when playback pauses or stops. Every change of speed starts
/// from the angle and speed the disc has at that moment, so nothing jumps.
struct DiscView: NSViewRepresentable {
    var cover: CGImage
    var spinning: Bool

    func makeNSView(context: Context) -> DiscNSView { DiscNSView() }

    func updateNSView(_ v: DiscNSView, context: Context) {
        v.setCover(cover)
        v.setSpinning(spinning)
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
    private let disc = CALayer()
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
        layer?.addSublayer(disc)
        disc.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
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
