import SwiftUI

struct CornerHunterView: View {
    let isPaused: Bool
    @State private var sim = CornerHunterSim()

    var body: some View {
        LoopHost(isPaused: isPaused) { date, ctx, size in
            sim.render(date, &ctx, size)
        }
    }
}

/// A "LOCK IN" badge bouncing at constant speed. At some wall hits the direction is re-aimed
/// (speed unchanged) using the unfolded-plane trick so that it lands exactly in a corner.
final class CornerHunterSim {
    private let clock = LoopClock()
    private var rng = SplitMix64(seed: 0xC0_4DE5)
    private var time = 0.0

    // Layout (recomputed every frame from the canvas size)
    private var cw = 0.0, ch = 0.0
    private var bw = 100.0, bh = 40.0
    private var travelX = 1.0, travelY = 1.0
    private var speed = 250.0
    private var sized = false

    // Badge state: top-left of badge within [0,travelX] x [0,travelY]
    private var x = 0.0, y = 0.0
    private var vx = 1.0, vy = 1.0
    private var hue = 0.52
    private var shownHue = 0.52
    private var pulse = 0.0

    private var nearHits = 0
    private var corners = 0
    private var hitsUntilSteer = 3
    private var targeting = false
    private var targetRight = false, targetBottom = false
    private var cornerCooldown = 0.0

    // Celebration
    private var celebrate = -1.0
    private var flash = 0.0
    private var shake = 0.0
    private var shockCorner = CGPoint.zero
    private var confetti = SparkPool(capacity: 120)
    private var impact = SparkPool(capacity: 48)

    private static let ghostCount = 9
    private var ghostX = [Double](repeating: 0, count: ghostCount)
    private var ghostY = [Double](repeating: 0, count: ghostCount)
    private var ghostH = [Double](repeating: 0, count: ghostCount)
    private var ghostHead = 0
    private var ghostTimer = 0.0

    private func layout(_ w: Double, _ h: Double) {
        let base = min(w, h)
        let nbw = clamp(base * 0.52, 90, 300)
        let nbh = nbw / 5.6 * 2.1
        let ntx = max(1, w - nbw), nty = max(1, h - nbh)
        let nspeed = clamp(0.30 * hypot(w, h), 140, 520)
        if !sized {
            sized = true
            x = ntx * 0.3; y = nty * 0.2
            let a = 0.85
            vx = cos(a) * nspeed; vy = sin(a) * nspeed
        } else if abs(ntx - travelX) > 1 || abs(nty - travelY) > 1 {
            x = x / travelX * ntx
            y = y / travelY * nty
            targeting = false
            hitsUntilSteer = 1
        }
        bw = nbw; bh = nbh; travelX = ntx; travelY = nty; cw = w; ch = h
        speed = nspeed
        let cur = hypot(vx, vy)
        if cur > 1e-6 { vx *= speed / cur; vy *= speed / cur }
    }

    /// Re-aim at a corner reachable after some wall bounces, keeping the current speed.
    private func steer() {
        let W = travelX, H = travelY
        let sxs: Double = vx >= 0 ? 1 : -1
        let sys: Double = vy >= 0 ? 1 : -1
        let qx = sxs > 0 ? x : 2 * W - x
        let qy = sys > 0 ? y : 2 * H - y
        let m0 = Int((qx / W + 1e-9).rounded(.down)) + 1
        let n0 = Int((qy / H + 1e-9).rounded(.down)) + 1
        let diag = hypot(W, H)
        let curSlope = max(0.05, abs(vy) / max(abs(vx), 1e-6))
        var best = (m: m0, n: n0, penalty: Double.infinity)
        for i in 0...4 {
            for j in 0...4 {
                let m = m0 + i, n = n0 + j
                let dx = Double(m) * W - qx, dy = Double(n) * H - qy
                if dx < 1 || dy < 1 { continue }
                let len = hypot(dx, dy)
                let slope = dy / dx
                var pen = abs(log(slope / curSlope)) + 0.45 * len / diag
                if slope < 0.3 || slope > 3.4 { pen += 5 }
                if len < 0.9 * diag { pen += 3 }
                if pen < best.penalty { best = (m, n, pen) }
            }
        }
        let dx = Double(best.m) * W - qx, dy = Double(best.n) * H - qy
        let len = hypot(dx, dy)
        guard len > 1e-6 else { return }
        vx = sxs * speed * dx / len
        vy = sys * speed * dy / len
        targeting = true
        targetRight = best.m % 2 != 0
        targetBottom = best.n % 2 != 0
    }

    private func onHit(hitX: Bool, hitY: Bool) {
        hue += 0.137
        pulse = 1
        let stepTravel = speed / 120
        // Distance of the other axis from its nearest wall.
        let nearY = min(y, travelY - y), nearX = min(x, travelX - x)
        let exact = (hitX && hitY) || (hitX && nearY < stepTravel * 1.5) || (hitY && nearX < stepTravel * 1.5)
        let near = (hitX && nearY < travelY * 0.12) || (hitY && nearX < travelX * 0.12)

        // Contact point for sparks
        let contact = CGPoint(x: (hitX ? (vx > 0 ? x : x + bw) : x + bw / 2), y: (hitY ? (vy > 0 ? y : y + bh) : y + bh / 2))
        for _ in 0..<6 {
            var s = Spark()
            s.x = contact.x; s.y = contact.y
            let a = rng.range(0, 2 * .pi)
            let v = rng.range(40, 160) * speed / 250
            s.vx = cos(a) * v + (hitX ? (vx > 0 ? 1 : -1) * 60 : 0)
            s.vy = sin(a) * v + (hitY ? (vy > 0 ? 1 : -1) * 60 : 0)
            s.life = rng.range(0.25, 0.5); s.maxLife = s.life
            s.hue = hue + rng.range(-0.06, 0.06)
            s.size = rng.range(1.5, 3.5)
            impact.emit(s)
        }

        if exact && cornerCooldown <= 0 {
            cornerCooldown = 0.25
            corners += 1
            nearHits += 1
            targeting = false
            hitsUntilSteer = rng.int(5, 9)
            startCelebration(right: x > travelX / 2, bottom: y > travelY / 2)
            return
        }
        if near { nearHits += 1 }
        if !targeting {
            hitsUntilSteer -= 1
            if hitsUntilSteer <= 0 { steer() }
        }
    }

    private func startCelebration(right: Bool, bottom: Bool) {
        celebrate = 0
        flash = 1
        shake = 1
        let corner = CGPoint(x: right ? cw : 0, y: bottom ? ch : 0)
        shockCorner = corner
        let k = clamp(min(cw, ch) / 500, 0.5, 2.5)
        let inward = atan2(bottom ? -1.0 : 1.0, right ? -1.0 : 1.0)
        for _ in 0..<110 {
            var s = Spark()
            s.x = corner.x; s.y = corner.y
            let a = inward + rng.range(-0.95, 0.95)
            let v = rng.range(250, 1000) * k
            s.vx = cos(a) * v; s.vy = sin(a) * v - 120 * k
            s.life = rng.range(1.6, 3.0); s.maxLife = s.life
            s.hue = rng.range(0, 1)
            s.size = rng.range(5, 11) * k
            s.rot = rng.range(0, 6.28); s.vrot = rng.range(-9, 9)
            confetti.emit(s)
        }
    }

    private func physics(_ dt: Double) {
        x += vx * dt
        y += vy * dt
        var hitX = false, hitY = false
        if x < 0 { x = -x; vx = abs(vx); hitX = true } else if x > travelX { x = 2 * travelX - x; vx = -abs(vx); hitX = true }
        if y < 0 { y = -y; vy = abs(vy); hitY = true } else if y > travelY { y = 2 * travelY - y; vy = -abs(vy); hitY = true }
        if hitX || hitY { onHit(hitX: hitX, hitY: hitY) }
    }

    private func step(_ dt: Double) {
        time += dt
        cornerCooldown = max(0, cornerCooldown - dt)
        let n = max(1, Int((dt / (1.0 / 120.0)).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n { physics(h) }

        shownHue += (hue - shownHue) * min(1, dt * 9)
        pulse = max(0, pulse - dt * 5)
        flash = max(0, flash - dt * 2.8)
        shake = max(0, shake - dt * 2.5)
        if celebrate >= 0 {
            celebrate += dt
            if celebrate > 2.2 { celebrate = -1 }
        }
        let k = clamp(min(cw, ch) / 500, 0.5, 2.5)
        confetti.step(dt, gravity: 900 * k, drag: 0.9)
        impact.step(dt, gravity: 0, drag: 3)

        ghostTimer += dt
        if ghostTimer > 0.035 {
            ghostTimer = 0
            ghostX[ghostHead] = x; ghostY[ghostHead] = y; ghostH[ghostHead] = shownHue
            ghostHead = (ghostHead + 1) % Self.ghostCount
        }
    }

    func render(_ date: Date, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        guard w > 8, h > 8 else { return }
        layout(w, h)
        let dt = clock.delta(date)
        if dt > 0 { step(dt) }

        let base = min(w, h)
        let hueC = shownHue

        // Background wash and grid
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .radialGradient(
            Gradient(colors: [Neon.color(hueC, s: 0.8, b: 0.5, a: 0.30), .clear]),
            center: CGPoint(x: x + bw / 2, y: y + bh / 2), startRadius: 0, endRadius: max(w, h) * 0.65))
        let gs = max(26, base / 9)
        var grid = Path()
        var gx = (fract(time * 0.02) * gs)
        while gx < w { grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: h)); gx += gs }
        var gy = (fract(time * 0.02) * gs)
        while gy < h { grid.move(to: CGPoint(x: 0, y: gy)); grid.addLine(to: CGPoint(x: w, y: gy)); gy += gs }
        ctx.stroke(grid, with: .color(Neon.color(hueC, s: 0.4, a: 0.05)), lineWidth: 1)

        var c = ctx
        if shake > 0 {
            let m = shake * shake * base * 0.015
            c.translateBy(x: sin(time * 90) * m, y: cos(time * 77) * m)
        }

        drawCornerBrackets(&c, w: w, h: h, base: base, hueC: hueC)

        // Ghost afterimages
        for i in 0..<Self.ghostCount {
            let idx = (ghostHead + i) % Self.ghostCount
            let f = Double(i + 1) / Double(Self.ghostCount)
            let r = CGRect(x: ghostX[idx], y: ghostY[idx], width: bw, height: bh)
            c.stroke(Path(roundedRect: r, cornerRadius: bh * 0.32),
                     with: .color(Neon.color(ghostH[idx], a: 0.16 * f * f)), lineWidth: 1.5)
        }

        // Impact sparks
        c.blendMode = .plusLighter
        for s in impact.items where s.life > 0 {
            let f = s.life / s.maxLife
            let r = s.size * (0.4 + f)
            c.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)),
                   with: .color(Neon.color(s.hue, s: 0.5, a: f)))
        }
        c.blendMode = .normal

        drawBadge(&c, hueC: hueC)

        // Celebration
        if celebrate >= 0 { drawCelebration(&c, w: w, h: h, base: base) }
        for s in confetti.items where s.life > 0 {
            let f = min(1, s.life / s.maxLife * 2)
            var cc = c
            cc.translateBy(x: s.x, y: s.y)
            cc.rotate(by: .radians(s.rot))
            let sq = abs(cos(s.rot * 0.7))
            cc.fill(Path(CGRect(x: -s.size / 2, y: -s.size * 0.3 * sq, width: s.size, height: s.size * 0.6 * sq + 0.5)),
                    with: .color(Neon.color(s.hue, s: 0.85, a: f)))
        }
        if flash > 0 {
            ctx.blendMode = .plusLighter
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Neon.color(hueC, s: 0.25, a: 0.38 * flash * flash)))
            ctx.blendMode = .normal
        }

        // HUD
        let fs = clamp(base * 0.045, 11, 26)
        let margin = max(8, fs * 0.7)
        drawText(&ctx, "NEAR \(nearHits)", size: fs, color: Neon.color(hueC, s: 0.35, a: 0.9),
                 at: CGPoint(x: margin, y: margin), anchor: .topLeading, tracking: fs * 0.05)
        drawText(&ctx, "CORNERS \(corners)", size: fs, color: Neon.rgb(1, 0.85, 0.3, 0.95),
                 at: CGPoint(x: w - margin, y: margin), anchor: .topTrailing, tracking: fs * 0.05)
    }

    private func drawCornerBrackets(_ c: inout GraphicsContext, w: Double, h: Double, base: Double, hueC: Double) {
        let len = base * 0.07
        let inset = 5.0
        for (right, bottom) in [(false, false), (true, false), (false, true), (true, true)] {
            let ox = right ? w - inset : inset, oy = bottom ? h - inset : inset
            let dx = right ? -1.0 : 1.0, dy = bottom ? -1.0 : 1.0
            let isTarget = targeting && targetRight == right && targetBottom == bottom
            let pulse = isTarget ? 0.5 + 0.5 * sin(time * 8) : 0
            let L = len * (isTarget ? 1.4 : 1)
            var p = Path()
            p.move(to: CGPoint(x: ox + dx * L, y: oy))
            p.addLine(to: CGPoint(x: ox, y: oy))
            p.addLine(to: CGPoint(x: ox, y: oy + dy * L))
            c.stroke(p, with: .color(Neon.color(hueC, a: isTarget ? 0.9 : 0.28)), style: StrokeStyle(lineWidth: isTarget ? 3 : 2, lineCap: .round, lineJoin: .round))
            if isTarget {
                c.blendMode = .plusLighter
                c.stroke(p, with: .color(Neon.color(hueC, a: 0.25 + 0.2 * pulse)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                let rr = len * (0.8 + 0.7 * fract(time * 1.3))
                c.stroke(Path(ellipseIn: CGRect(x: ox - rr, y: oy - rr, width: rr * 2, height: rr * 2)),
                         with: .color(Neon.color(hueC, a: 0.5 * (1 - fract(time * 1.3)))), lineWidth: 2)
                c.blendMode = .normal
            }
        }
    }

    private func drawBadge(_ c: inout GraphicsContext, hueC: Double) {
        let scale = 1 + 0.08 * pulse
        var b = c
        let cx = x + bw / 2, cy = y + bh / 2
        b.translateBy(x: cx, y: cy)
        b.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
        let shape = Path(roundedRect: rect, cornerRadius: bh * 0.32)
        b.blendMode = .plusLighter
        for (mult, op) in [(0.55, 0.06), (0.34, 0.10), (0.18, 0.18)] {
            b.stroke(shape, with: .color(Neon.color(hueC, a: op + 0.08 * pulse)), lineWidth: bh * mult)
        }
        b.blendMode = .normal
        b.fill(shape, with: .linearGradient(
            Gradient(colors: [Neon.color(hueC, s: 0.75, b: 0.42), Neon.color(hueC + 0.08, s: 0.95, b: 0.14)]),
            startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        // Glossy top band
        var gloss = Path()
        gloss.addRoundedRect(in: CGRect(x: rect.minX + bh * 0.08, y: rect.minY + bh * 0.07, width: bw - bh * 0.16, height: bh * 0.34),
                             cornerSize: CGSize(width: bh * 0.24, height: bh * 0.24))
        b.fill(gloss, with: .color(.white.opacity(0.10)))
        b.stroke(shape, with: .color(Neon.color(hueC, s: 0.35)), lineWidth: max(2, bh * 0.05))
        let fs = bh / 2.1
        drawText(&b, "LOCK IN", size: fs, color: Neon.color(hueC, s: 0.9, a: 0.35), at: CGPoint(x: 0, y: 1.5), tracking: fs * 0.04)
        drawText(&b, "LOCK IN", size: fs, color: .white, at: .zero, tracking: fs * 0.04)
    }

    private func drawCelebration(_ c: inout GraphicsContext, w: Double, h: Double, base: Double) {
        let t = celebrate
        // Shockwave from the corner
        let sw = smoothstep(0, 0.9, t)
        let rad = sw * hypot(w, h) * 0.7
        c.blendMode = .plusLighter
        c.stroke(Path(ellipseIn: CGRect(x: shockCorner.x - rad, y: shockCorner.y - rad, width: rad * 2, height: rad * 2)),
                 with: .color(Neon.rgb(1, 0.9, 0.5, 0.6 * (1 - sw))), lineWidth: 3 + 10 * (1 - sw))
        c.blendMode = .normal

        let appear = clamp(t / 0.4, 0, 1)
        let back = 1 + 2.70158 * pow(appear - 1, 3) + 1.70158 * pow(appear - 1, 2)
        let fade = 1 - smoothstep(1.5, 2.2, t)
        let fs = clamp(min(w * 0.17, h * 0.11), 18, 110)
        let pos = CGPoint(x: w / 2, y: h * 0.40)
        var l = c
        l.translateBy(x: pos.x, y: pos.y)
        l.scaleBy(x: back, y: back)
        l.rotate(by: .radians(-0.06))
        l.opacity = fade
        let off = fs * 0.05
        drawText(&l, "CORNER!", size: fs, color: Neon.rgb(0, 0.9, 1, 0.9), at: CGPoint(x: -off, y: off), tracking: fs * 0.02)
        drawText(&l, "CORNER!", size: fs, color: Neon.rgb(1, 0.2, 0.7, 0.9), at: CGPoint(x: off, y: -off), tracking: fs * 0.02)
        drawText(&l, "CORNER!", size: fs, color: .white, at: .zero, tracking: fs * 0.02)
    }
}
