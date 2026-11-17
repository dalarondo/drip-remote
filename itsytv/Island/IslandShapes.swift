import SwiftUI

// The shapes that make command center and the remote pour out of the island.
// Pure geometry, no app state – kept apart so the unit tests can compile them alone.

/// The visible region of command center, animated by `progress` (0 → 1) as a drip:
///
/// 1. **Swell** (0 – 0.35): a drop of black gathers under the island and hangs from it
///    by a thinning neck.
/// 2. **Fall** (0.35 – 0.55): the drop lets go and falls, speeding up, to the middle of
///    the screen while the neck snaps back into the island.
/// 3. **Splash and flood** (0.55 – 1): it lands squashed, throws up droplets, and spreads
///    outward with a rippling edge until it covers the screen.
///
/// Run backwards, the black gathers into a drop and is drawn back up into the island.
struct IslandReveal: Shape {
    /// What the drip comes out of: the island widget's pill when it is closed, or its
    /// expanded card when it is open. Flat on top, rounded below.
    let source: CGRect
    let sourceRadius: CGFloat
    /// False while the real island widget is still on screen underneath: the drip then
    /// only draws the drop coming out of it, and the widget keeps showing its own content
    /// until the flood covers it. True when there is no widget to show (first connect, exit).
    var includeSource = true
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let swellEnd: CGFloat = 0.32
    private static let fallEnd: CGFloat = 0.45

    // Every piece of the shape is drawn in the same direction (clockwise on screen).
    // With mixed directions, the default winding rule cancels where two pieces overlap
    // and punches a see-through hole – e.g. where the drop meets the island.
    private static func addOval(_ path: inout Path, in r: CGRect) {
        let steps = 40
        for i in 0..<steps {
            let a = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let point = CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }

    /// Flat top, rounded bottom corners – the island widget's outline. Clockwise.
    private static func addSource(_ path: inout Path, in r: CGRect, radius: CGFloat) {
        let rad = min(radius, r.width / 2, r.height)
        let steps = 12
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        for i in 0...steps {            // bottom-right corner
            let a = CGFloat(i) / CGFloat(steps) * .pi / 2
            path.addLine(to: CGPoint(x: r.maxX - rad + cos(a) * rad, y: r.maxY - rad + sin(a) * rad))
        }
        for i in 0...steps {            // bottom-left corner
            let a = .pi / 2 + CGFloat(i) / CGFloat(steps) * .pi / 2
            path.addLine(to: CGPoint(x: r.minX + rad + cos(a) * rad, y: r.maxY - rad + sin(a) * rad))
        }
        path.closeSubpath()
    }

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        if p >= 0.999 { return Path(rect) }

        var path = Path()
        // The source is always part of the shape, so the drip is one piece with the island.
        if includeSource { Self.addSource(&path, in: source, radius: sourceRadius) }
        guard p > 0 else { return path }

        let cx = source.midX
        // In proportion to what it falls from: a bigger drop from the open card than from the pill.
        let dropRadius = min(130, max(70, source.width * 0.28))
        let hangY = source.maxY + dropRadius * 1.25                    // where the drop hangs before letting go
        let landY = max(rect.height * 0.5, hangY + dropRadius * 1.5)   // where it lands

        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func easeOut(_ t: CGFloat) -> CGFloat { 1 - (1 - t) * (1 - t) }
        func easeInOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

        if p < Self.swellEnd {
            // 1. Swell: the drop grows and sinks, joined to the island by a pinching neck.
            //    It wobbles as it hangs – breathing wide / tall and swaying slightly.
            let t = p / Self.swellEnd
            let e = easeOut(t)
            let wobble = sin(t * .pi * 5) * (1 - t * 0.4)
            // The drop starts hidden inside the source's bottom edge and grows out of it,
            // so nothing bulges around the island itself.
            let radius = lerp(4, dropRadius, e)
            let rx = radius * (1 + 0.10 * wobble), ry = radius * (1 - 0.10 * wobble)
            let sway = sin(t * .pi * 3) * 2.5 * e
            let centreY = lerp(source.maxY - 6, hangY, e) + wobble * 3 * e
            // The neck is a funnel: it starts as wide as the source's flat bottom edge, so the
            // drop flows out of the whole edge rather than dangling from a stem, and narrows
            // as the drop sinks.
            let neckTop = source.maxY - 2
            let edgeHalf = max(dropRadius * 0.5, source.width / 2 - sourceRadius)
            let topHalf = lerp(min(edgeHalf, dropRadius * 1.5), dropRadius * 0.4, e)
            let pinch = lerp(topHalf, max(6, dropRadius * 0.14), e)          // …and at its thinnest
            let midY = (neckTop + centreY) / 2
            // Clockwise (right side down, left side up), matching every other piece.
            path.move(to: CGPoint(x: cx + topHalf, y: neckTop))
            path.addQuadCurve(to: CGPoint(x: cx + sway + rx * 0.7, y: centreY), control: CGPoint(x: cx + sway * 0.5 + pinch, y: midY))
            path.addLine(to: CGPoint(x: cx + sway - rx * 0.7, y: centreY))
            path.addQuadCurve(to: CGPoint(x: cx - topHalf, y: neckTop), control: CGPoint(x: cx + sway * 0.5 - pinch, y: midY))
            path.closeSubpath()
            Self.addOval(&path, in: CGRect(x: cx + sway - rx, y: centreY - ry, width: rx * 2, height: ry * 2))
        } else if p < Self.fallEnd {
            // 2. Fall: gravity (t²), with the drop stretching a little as it speeds up.
            let t = (p - Self.swellEnd) / (Self.fallEnd - Self.swellEnd)
            let centreY = lerp(hangY, landY, t * t)
            let stretch = 1 + 0.5 * t
            let w = dropRadius / sqrt(stretch), h = dropRadius * stretch
            Self.addOval(&path, in: CGRect(x: cx - w, y: centreY - h, width: w * 2, height: h * 2))
            // What's left of the neck snaps back up into the island, with a little bounce.
            let snap = min(1, t * 2.2)
            let stub = lerp(dropRadius * 0.9, 0, snap) * (1 + 0.3 * sin(snap * .pi * 3))
            if stub > 0.5 {
                Self.addOval(&path, in: CGRect(x: cx - dropRadius * 0.3, y: source.maxY - stub * 0.5,
                                           width: dropRadius * 0.6, height: stub))
            }
        } else {
            // 3. Splash and flood.
            let c = (p - Self.fallEnd) / (1 - Self.fallEnd)
            let e = easeInOut(c)
            let reach = hypot(max(cx, rect.width - cx), max(landY, rect.height - landY)) + 8
            let radius = lerp(dropRadius, reach, e)

            // The blob's edge ripples – big lobes right after impact, settling to a clean
            // circle as it spreads – and it lands squashed flat before rounding out.
            let ripple = 0.38 * pow(1 - c, 1.3)
            let squash = lerp(0.4, 1, min(1, c * 3))
            let spin = c * 2.2
            let steps = 96
            for i in 0...steps {
                let angle = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let r = radius * (1 + ripple * sin(7 * angle + spin) + ripple * 0.5 * sin(11 * angle - spin * 1.7))
                let point = CGPoint(x: cx + cos(angle) * r, y: landY + sin(angle) * r * squash)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()

            // Droplets thrown up and out by the impact, falling back under gravity and
            // shrinking away (the flood overtakes most of them).
            let life = min(1, c / 0.7)
            if life < 1 {
                // A crown of droplets, in two rings: big slow ones and small fast ones.
                let count = 18
                for i in 0..<count {
                    let f = CGFloat(i) / CGFloat(count - 1)
                    let fast = i % 2 == 1
                    let angle = lerp(-.pi * 0.96, -.pi * 0.04, f)               // an upward fan
                    let speed = rect.height * (fast ? 0.95 : 0.6) * (0.8 + 0.3 * abs(sin(CGFloat(i) * 2.4)))
                    let x = cx + cos(angle) * speed * life
                    let y = landY + sin(angle) * speed * life + rect.height * 0.75 * life * life
                    let size = (fast ? 9 : 20) * (0.7 + 0.5 * abs(sin(CGFloat(i) * 1.7))) * (1 - life * life)
                    if size > 0.5 {
                        Self.addOval(&path, in: CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2))
                    }
                }
                // The rebound: a column of liquid thrown straight back up from the impact,
                // rising and collapsing, with a bead pinching off its tip.
                let rise = sin(.pi * life)
                let columnH = dropRadius * 3.2 * rise
                let columnW = dropRadius * 0.55 * (1 - life * 0.5)
                if columnH > 1 {
                    Self.addOval(&path, in: CGRect(x: cx - columnW / 2, y: landY - columnH, width: columnW, height: columnH))
                    let bead = dropRadius * 0.3 * rise
                    Self.addOval(&path, in: CGRect(x: cx - bead, y: landY - columnH - bead * 1.6, width: bead * 2, height: bead * 2))
                }
            }
        }
        return path
    }
}

/// The remote's outline: a neck coming down from the island that flares into a rounded
/// body. `progress` 0 → 1 pours it out in one smooth motion – the neck extends first,
/// then the body widens and lengthens beneath it. No wobble, no splash.
struct RemotePour: Shape {
    static let neckHeight: CGFloat = 36
    /// The width of whatever it hangs from – the island widget's pill or its open card.
    var neckWidth: CGFloat

    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        guard p > 0.001 else { return Path() }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func smooth(_ t: CGFloat) -> CGFloat { let c = min(1, max(0, t)); return c * c * (3 - 2 * c) }

        let cx = rect.midX
        let neckW = min(neckWidth, rect.width)
        let neckDown = smooth(p / 0.3)                 // the neck reaches down first…
        let spread = smooth((p - 0.15) / 0.85)         // …then the body spreads out under it

        let bodyY = Self.neckHeight * neckDown
        let bodyW = lerp(neckW, rect.width, spread)
        let bodyH = max(1, lerp(0, rect.height - Self.neckHeight, spread))
        let radius = min(lerp(neckW / 2, 26, spread), bodyW / 2, bodyH / 2)
        let body = Path(roundedRect: CGRect(x: cx - bodyW / 2, y: bodyY, width: bodyW, height: bodyH),
                        cornerRadius: radius, style: .continuous)

        // Neck: straight sides that flare out into the top of the body.
        let flare = max(0, min(22, (bodyW - neckW) / 2 - radius * 0.3, bodyY))
        var neck = Path()
        neck.move(to: CGPoint(x: cx - neckW / 2, y: 0))
        neck.addLine(to: CGPoint(x: cx + neckW / 2, y: 0))
        neck.addLine(to: CGPoint(x: cx + neckW / 2, y: bodyY - flare))
        neck.addQuadCurve(to: CGPoint(x: cx + neckW / 2 + flare, y: bodyY + 1),
                          control: CGPoint(x: cx + neckW / 2, y: bodyY))
        neck.addLine(to: CGPoint(x: cx - neckW / 2 - flare, y: bodyY + 1))
        neck.addQuadCurve(to: CGPoint(x: cx - neckW / 2, y: bodyY - flare),
                          control: CGPoint(x: cx - neckW / 2, y: bodyY))
        neck.closeSubpath()

        // A true union, so the overlap can never cancel into a hole.
        return neck.union(body)
    }
}
