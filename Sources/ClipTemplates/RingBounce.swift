import SwiftUI

struct RingBounceView: View {
    let isPaused: Bool
    @State private var sim = RingBounceSim()

    var body: some View {
        LoopHost(isPaused: isPaused) { date, ctx, size in
            sim.render(date, &ctx, size)
        }
    }
}

/// A ball with gravity inside a rotating ring that has a gap. Works in "ring units":
/// the ring has radius 1 and is centred on the origin; y points down.
final class RingBounceSim {
    private enum Phase { case playing, escaping, burst }

    private let clock = LoopClock()
    private var rng = SplitMix64(seed: 0xB0_0BCE)
    private var time = 0.0

    // Ring
    private var ringAngle = 0.0
    private var ringSpin = 0.6
    private var gapHalf = 0.31
    private var ringAlpha = 0.0
    private var ringHue = 0.55
    private var flash = 0.0
    private var hitAngle = 0.0

    // Ball
    private var bx = 0.0, by = -0.15
    private var bvx = 0.5, bvy = 0.0
    private var br = 0.055
    private var hue = 0.55
    private var ballScale = 0.0
    private var squash = 0.0

    private var phase = Phase.playing
    private var phaseT = 0.0
    private var bounces = 0
    private var rings = 1
    private var limit = 11

    private static let trailCount = 46
    private var trailX = [Double](repeating: 0, count: trailCount)
    private var trailY = [Double](repeating: 0, count: trailCount)
    private var trailR = [Double](repeating: 0, count: trailCount)
    private var trailH = [Double](repeating: 0, count: trailCount)
    private var trailAge = [Double](repeating: 99, count: trailCount)
    private var trailHead = 0
    private var trailTimer = 0.0

    private var sparks = SparkPool(capacity: 180)

    private let gravity = 2.4
    private let maxSpeed = 3.6

    init() { newRound(first: true) }

    private func newRound(first: Bool) {
        ringAngle = rng.range(0, 2 * .pi)
        ringSpin = rng.range(0.45, 0.8) * (rings % 2 == 0 ? -1 : 1)
        gapHalf = rng.range(0.30, 0.34)
        limit = rng.int(8, 13)
        bounces = 0
        br = 0.055
        bx = rng.range(-0.1, 0.1)
        by = -0.2
        bvx = rng.range(0.4, 0.9) * rng.sign()
        bvy = rng.range(-0.3, 0.3)
        ballScale = 0
        phase = .playing
        phaseT = 0
        if !first { ringAlpha = 0 }
        for i in 0..<Self.trailCount { trailAge[i] = 99 }
    }

    private func onBounce(nx: Double, ny: Double) {
        bounces += 1
        hue += 0.065
        br = min(0.055 + 0.012 * Double(bounces), 0.15)
        flash = 1
        squash = 1
        hitAngle = atan2(ny, nx)
        if bounces > limit { gapHalf = min(gapHalf + 0.05, 0.95) }
        for _ in 0..<7 {
            var s = Spark()
            s.x = nx * (1 - br * 0.2); s.y = ny * (1 - br * 0.2)
            let a = atan2(-ny, -nx) + rng.range(-1.1, 1.1)
            let v = rng.range(0.4, 1.3)
            s.vx = cos(a) * v; s.vy = sin(a) * v
            s.life = rng.range(0.25, 0.5); s.maxLife = s.life
            s.hue = hue + rng.range(-0.05, 0.05)
            s.size = rng.range(0.008, 0.016)
            sparks.emit(s)
        }
    }

    private func burst() {
        for _ in 0..<80 {
            var s = Spark()
            s.x = bx; s.y = by
            let a = rng.range(0, 2 * .pi)
            let v = rng.range(0.3, 2.4)
            s.vx = cos(a) * v; s.vy = sin(a) * v
            s.life = rng.range(0.6, 1.4); s.maxLife = s.life
            s.hue = hue + rng.range(-0.15, 0.15)
            s.size = rng.range(0.008, 0.025)
            sparks.emit(s)
        }
        phase = .burst
        phaseT = 0
        flash = 1
    }

    private func physics(_ dt: Double) {
        guard phase != .burst else { return }
        bvy += gravity * dt
        bx += bvx * dt
        by += bvy * dt
        let dist = (bx * bx + by * by).squareRoot()

        if phase == .playing {
            if dist > 1 {
                phase = .escaping
                phaseT = 0
            } else if dist + br >= 1 && dist > 1e-6 {
                let nx = bx / dist, ny = by / dist
                let ang = atan2(ny, nx)
                var delta = (ang - ringAngle).truncatingRemainder(dividingBy: 2 * .pi)
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                let inGap = abs(delta) < gapHalf - br * 0.55
                if !inGap {
                    let vn = bvx * nx + bvy * ny
                    if vn > 0 {
                        bvx -= 2 * vn * nx
                        bvy -= 2 * vn * ny
                        // The spinning wall drags the ball a little.
                        bvx += -ny * ringSpin * 0.22
                        bvy += nx * ringSpin * 0.22
                        let sp = (bvx * bvx + bvy * bvy).squareRoot()
                        if sp > maxSpeed { bvx *= maxSpeed / sp; bvy *= maxSpeed / sp }
                        onBounce(nx: nx, ny: ny)
                        bx = nx * (1 - br)
                        by = ny * (1 - br)
                    }
                }
            }
        } else if dist > 1 + br + 0.3 {
            burst()
        }
    }

    private func step(_ dt: Double) {
        time += dt
        flash = max(0, flash - dt * 3.2)
        squash = max(0, squash - dt * 5)
        ringAngle += ringSpin * dt
        ringHue += (hue - ringHue) * min(1, dt * 3)

        let n = max(1, Int((dt / (1.0 / 180.0)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n { physics(h) }

        switch phase {
        case .playing:
            ringAlpha = min(1, ringAlpha + dt * 2.2)
            ballScale = min(1, ballScale + dt * 3)
        case .escaping:
            phaseT += dt
            ringAlpha = min(1, ringAlpha + dt * 2.2)
        case .burst:
            phaseT += dt
            ringAlpha = max(0, ringAlpha - dt * 1.5)
            if phaseT > 1.25 {
                rings += 1
                newRound(first: false)
            }
        }

        // Trail
        for i in 0..<Self.trailCount { trailAge[i] += dt }
        if phase != .burst {
            trailTimer += dt
            if trailTimer >= 0.013 {
                trailTimer = 0
                trailX[trailHead] = bx; trailY[trailHead] = by
                trailR[trailHead] = br; trailH[trailHead] = hue
                trailAge[trailHead] = 0
                trailHead = (trailHead + 1) % Self.trailCount
            }
        }
        sparks.step(dt, gravity: 1.4, drag: 1.1)
    }

    func render(_ date: Date, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let dt = clock.delta(date)
        if dt > 0 { step(dt) }

        let w = size.width, h = size.height
        guard w > 8, h > 8 else { return }
        let tall = h > w * 1.1
        let R = min(w * 0.43, h * (tall ? 0.37 : 0.42))
        let c = CGPoint(x: w / 2, y: h * (tall ? 0.55 : 0.54))
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * R, y: c.y + y * R) }

        // Background glow follows the ball's hue.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .radialGradient(
            Gradient(colors: [Neon.color(hue, s: 0.8, b: 0.55, a: 0.35), Neon.color(hue + 0.15, s: 0.9, b: 0.2, a: 0.10), .clear]),
            center: c, startRadius: 0, endRadius: R * 1.9))
        // Faint guides
        for f in [0.5, 0.75] {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - R * f, y: c.y - R * f, width: R * f * 2, height: R * f * 2)),
                       with: .color(Neon.color(hue, s: 0.5, a: 0.06)), lineWidth: 1)
        }
        // Drifting motes
        ctx.blendMode = .plusLighter
        for i in 0..<30 {
            let sp = 0.01 + hash01(i * 5) * 0.03
            let y = h - fract(hash01(i * 5 + 1) + time * sp) * h
            let x = hash01(i * 5 + 2) * w + sin(time * 0.3 + Double(i)) * 6
            let s = 1 + hash01(i * 5 + 3) * 1.8
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(Neon.color(hue + hash01(i) * 0.3, s: 0.5, a: 0.35)))
        }
        ctx.blendMode = .normal

        // Ring
        let a = ringAlpha
        if a > 0.01 {
            let scale = phase == .burst ? 1 + 0.12 * smoothstep(0, 1.2, phaseT) : 1
            let rr = R * scale
            let a0 = ringAngle + gapHalf
            let a1 = ringAngle + 2 * .pi - gapHalf
            var arc = Path()
            let steps = 90
            for i in 0...steps {
                let t = a0 + (a1 - a0) * Double(i) / Double(steps)
                let p = CGPoint(x: c.x + cos(t) * rr, y: c.y + sin(t) * rr)
                if i == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
            }
            let lw = R * 0.04
            let col = ringHue + 0.5
            ctx.blendMode = .plusLighter
            for (mult, op) in [(5.0, 0.07), (3.2, 0.12), (1.9, 0.22)] {
                ctx.stroke(arc, with: .color(Neon.color(col, a: op * a)), style: StrokeStyle(lineWidth: lw * mult, lineCap: .round))
            }
            ctx.stroke(arc, with: .color(Neon.color(col, s: 0.55, a: a)), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            if flash > 0 && phase == .playing {
                var hit = Path()
                for i in 0...16 {
                    let t = hitAngle - 0.4 + 0.8 * Double(i) / 16
                    let p = CGPoint(x: c.x + cos(t) * rr, y: c.y + sin(t) * rr)
                    if i == 0 { hit.move(to: p) } else { hit.addLine(to: p) }
                }
                ctx.stroke(hit, with: .color(.white.opacity(0.9 * flash * a)), style: StrokeStyle(lineWidth: lw * 1.4, lineCap: .round))
                ctx.stroke(hit, with: .color(Neon.color(hue, a: 0.4 * flash * a)), style: StrokeStyle(lineWidth: lw * 4, lineCap: .round))
            }
            // Gap end caps
            for t in [a0 - 2 * gapHalf, a0] {
                let p = CGPoint(x: c.x + cos(t) * rr, y: c.y + sin(t) * rr)
                let r = lw * 1.4
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.9 * a)))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.6, y: p.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                         with: .color(Neon.color(col, a: 0.25 * a)))
            }
            ctx.blendMode = .normal
        }

        // Trail
        ctx.blendMode = .plusLighter
        for i in 0..<Self.trailCount {
            let age = trailAge[i]
            let life = 0.62
            if age > life { continue }
            let f = 1 - age / life
            let r = trailR[i] * R * (0.35 + 0.65 * f)
            let p = pt(trailX[i], trailY[i])
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(Neon.color(trailH[i], s: 0.85, a: 0.38 * f * f)))
        }

        // Ball
        if phase != .burst && ballScale > 0.01 {
            let p = pt(bx, by)
            let sq = 1 + 0.18 * squash
            let r = br * R * ballScale * sq
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.6, y: p.y - r * 2.6, width: r * 5.2, height: r * 5.2)),
                     with: .color(Neon.color(hue, a: 0.10)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.7, y: p.y - r * 1.7, width: r * 3.4, height: r * 3.4)),
                     with: .color(Neon.color(hue, a: 0.22)))
            ctx.blendMode = .normal
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [.white, Neon.color(hue, s: 0.8), Neon.color(hue + 0.08, s: 0.95, b: 0.8)]),
                                           center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.35), startRadius: 0, endRadius: r * 1.2))
            ctx.blendMode = .plusLighter
        }

        // Sparks
        for s in sparks.items where s.life > 0 {
            let f = s.life / s.maxLife
            let p = pt(s.x, s.y)
            let r = max(1, s.size * R * (0.4 + f))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(Neon.color(s.hue, s: 0.6, a: f)))
        }
        ctx.blendMode = .normal

        if phase == .burst && flash > 0 {
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Neon.color(hue, s: 0.3, a: 0.18 * flash)))
        }

        // HUD
        let fs = clamp(min(w, h) * 0.05, 12, 44)
        let hud: CGPoint
        let anchor: UnitPoint
        if tall {
            hud = CGPoint(x: w / 2, y: max(8, (c.y - R) * 0.5 - fs * 0.9))
            anchor = .top
        } else {
            hud = CGPoint(x: max(10, fs * 0.6), y: max(8, fs * 0.4))
            anchor = .topLeading
        }
        let hx = anchor == .top ? hud.x : hud.x
        drawText(&ctx, "BOUNCES", size: fs * 0.36, color: Neon.color(hue, s: 0.4, a: 0.8), at: CGPoint(x: hx, y: hud.y), anchor: anchor, tracking: fs * 0.12)
        let numPt = CGPoint(x: hx, y: hud.y + fs * 0.45)
        drawText(&ctx, String(bounces), size: fs, color: Neon.color(hue, a: 0.4), at: CGPoint(x: numPt.x + 1.5, y: numPt.y + 1.5), anchor: anchor)
        drawText(&ctx, String(bounces), size: fs, color: .white, at: numPt, anchor: anchor)
        drawText(&ctx, "RING #\(rings)", size: fs * 0.32, color: Neon.color(hue + 0.5, s: 0.5, a: 0.7),
                 at: CGPoint(x: hx, y: numPt.y + fs * 1.12), anchor: anchor, tracking: fs * 0.1)
    }
}
