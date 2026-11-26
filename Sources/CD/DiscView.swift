import AppKit
import QuartzCore
import SwiftUI

/// The album cover on a plain disc with a hole in the middle. The disc turns in Core Animation (the
/// render server does the work, not the app): it speeds up from rest with an ease-in, then spins at a
/// constant speed, and slows down to rest when playback pauses or stops. Every change of speed starts
/// from the angle and speed the disc has at that moment, so nothing jumps.
/// On hover the disc lifts off the window: its shadow fades in and it grows a little, with a small
/// "Change CD" label. Shadow, label and disc are layers of one view, so they move as one piece.
struct DiscView: NSViewRepresentable {
    var cover: CGImage
    var spinning: Bool
    var lifted = false
    /// False for a CD that is leaving: it drops back at once, with no shadow.
    var animateLift = true
    var label = "Change CD"
    /// Rise in from this far below (once, when the CD is put in).
    var enterFrom: CGFloat?
    /// Slide out by this much to the left (once, when the CD is taken out).
    var exitBy: CGFloat?

    func makeNSView(context: Context) -> DiscNSView { DiscNSView() }

    func updateNSView(_ v: DiscNSView, context: Context) {
        v.setCover(cover)
        v.setSpinning(spinning)
        v.setLifted(lifted, label: label, animated: animateLift)
        if let d = enterFrom { v.enter(from: d) }
        if let d = exitBy { v.exit(by: d) }
    }
}

/// The timing of a CD change, shared by the disc (Core Animation) and the title (SwiftUI), so the
/// title is uncovered exactly as the disc's edge passes.
enum Swap {
    static let exitDuration = 0.3
    static let exitCurve: (Float, Float, Float, Float) = (0.45, 0, 0.85, 0.35)
    static let enterDelay = 0.08
    static let enterDuration = 0.62
    static let enterCurve: (Float, Float, Float, Float) = (0.12, 0.72, 0.22, 1)

    static func timing(_ c: (Float, Float, Float, Float)) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: c.0, c.1, c.2, c.3)
    }
    static func animation(_ c: (Float, Float, Float, Float), _ duration: Double) -> Animation {
        .timingCurve(Double(c.0), Double(c.1), Double(c.2), Double(c.3), duration: duration)
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
    /// Holds the disc, its shadow and the label; scaled as one when the disc lifts.
    private let stack = CALayer()
    private let shadowLayer = CALayer()
    private let disc = CALayer()
    private let labelLayer = CALayer()
    private var lifted = false
    private var labelText = ""
    /// Size while lifted.
    static let liftScale: CGFloat = 1.035
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

    private var entered = false
    private var exited = false

    /// The CD rises from `distance` points below its place: moved by the render server, so it stays
    /// smooth however busy the app is while the new album appears.
    func enter(from distance: CGFloat) {
        guard !entered, let root = layer else { return }
        entered = true
        let a = CABasicAnimation(keyPath: "sublayerTransform")
        a.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, -distance, 0))
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.duration = Swap.enterDuration
        a.timingFunction = Swap.timing(Swap.enterCurve)
        a.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) + Swap.enterDelay
        a.fillMode = .backwards
        root.add(a, forKey: "enter")
    }

    /// The CD slides out to the left, speeding up, and fades a little.
    func exit(by distance: CGFloat) {
        guard !exited, let root = layer else { return }
        exited = true
        let from = root.presentation()?.sublayerTransform ?? root.sublayerTransform
        let to = CATransform3DMakeTranslation(-distance, 0, 0)
        root.removeAnimation(forKey: "enter")
        let move = CABasicAnimation(keyPath: "sublayerTransform")
        move.fromValue = NSValue(caTransform3D: from)
        move.toValue = NSValue(caTransform3D: to)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.6
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = Swap.exitDuration
        g.timingFunction = Swap.timing(Swap.exitCurve)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        root.add(g, forKey: "exit")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        // For the label's blur.
        layerUsesCoreImageFilters = true
        layer?.addSublayer(stack)
        for l in [shadowLayer, disc, labelLayer] { stack.addSublayer(l) }
        disc.contentsGravity = .resizeAspect
        // At rest the disc lies flat in its housing: no shadow. Lifted, a soft shadow below it.
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.32
        shadowLayer.shadowRadius = 13
        shadowLayer.shadowOffset = CGSize(width: 0, height: -6)
        shadowLayer.opacity = 0
        labelLayer.opacity = 0
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(6, forKey: kCIInputRadiusKey)
            labelLayer.filters = [blur]
        }
        labelLayer.contentsGravity = .center
    }

    /// Lifts the disc (shadow fades in, slightly larger, label shown) or lays it back down.
    func setLifted(_ on: Bool, label: String, animated: Bool = true) {
        if label != labelText { labelText = label; if !label.isEmpty { renderLabel() } }
        guard on != lifted else { return }
        lifted = on
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stack.removeAnimation(forKey: "lift")
            shadowLayer.opacity = on ? 1 : 0
            labelLayer.opacity = on ? 1 : 0
            stack.transform = on ? CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1) : CATransform3DIdentity
            CATransaction.commit()
            return
        }
        let dur = 0.3
        let timing = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(dur)
        CATransaction.setAnimationTimingFunction(timing)
        shadowLayer.opacity = on ? 1 : 0
        CATransaction.commit()
        if !labelText.isEmpty { animateLabel(on) }
        let from = stack.presentation()?.transform ?? stack.transform
        let to = on ? CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1) : CATransform3DIdentity
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = NSValue(caTransform3D: from)
        anim.toValue = NSValue(caTransform3D: to)
        anim.duration = dur
        anim.timingFunction = timing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stack.transform = to
        CATransaction.commit()
        stack.add(anim, forKey: "lift")
    }

    /// The label comes in just after the disc starts to lift: it rises a few points and comes into
    /// focus as it fades in. It leaves quicker, softening and fading in place.
    private func animateLabel(_ on: Bool) {
        let p = labelLayer.presentation()
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = p?.opacity ?? labelLayer.opacity
        opacity.toValue = on ? 1 : 0
        let blur = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        blur.fromValue = (p?.value(forKeyPath: "filters.blur.inputRadius") as? NSNumber) ?? (on ? 6 : 0)
        blur.toValue = on ? 0 : 4
        let g = CAAnimationGroup()
        var anims: [CAAnimation] = [opacity, blur]
        if on {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -7
            rise.toValue = 0
            anims.append(rise)
            g.beginTime = labelLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.07
            g.fillMode = .backwards
        }
        g.animations = anims
        g.duration = on ? 0.38 : 0.16
        g.timingFunction = on ? CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) : CAMediaTimingFunction(name: .easeIn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.opacity = on ? 1 : 0
        labelLayer.setValue(on ? 0 : 4, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
        labelLayer.add(g, forKey: "label")
    }

    private func renderLabel() {
        let scale = window?.backingScaleFactor ?? 2
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text = NSAttributedString(string: labelText, attributes: [.font: font, .foregroundColor: NSColor.white])
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        let ts = text.size()
        let ss = symbol?.size ?? .zero
        // One line in a small dark capsule, readable on any cover.
        let pad: CGFloat = 12, gap: CGFloat = 6
        let h = ceil(max(ts.height, ss.height)) + 10
        let size = NSSize(width: ceil(pad + ss.width + gap + ts.width + pad), height: h)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            symbol?.draw(in: NSRect(x: pad, y: (h - ss.height) / 2, width: ss.width, height: ss.height))
            text.draw(at: NSPoint(x: pad + ss.width + gap, y: (h - ts.height) / 2))
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
        // The stack is scaled about its centre when the disc lifts.
        stack.bounds = bounds
        stack.position = centre
        let local = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        for l in [shadowLayer, disc] as [CALayer] {
            l.bounds = full
            l.position = local
        }
        let ring = CGMutablePath()
        ring.addEllipse(in: full)
        let h = side * Face.hole
        ring.addEllipse(in: CGRect(x: side / 2 - h, y: side / 2 - h, width: 2 * h, height: 2 * h))
        shadowLayer.shadowPath = ring
        // Below the hole, as before.
        labelLayer.position = CGPoint(x: local.x, y: local.y - side * 0.24)
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
