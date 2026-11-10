import SwiftUI

struct NeonRunnerView: View {
    let isPaused: Bool
    @State private var sim = NeonRunnerSim()

    var body: some View {
        LoopHost(isPaused: isPaused) { date, ctx, size in
            sim.render(date, &ctx, size)
        }
    }
}

/// Pseudo-3D endless lane runner. World distance `z` increases away from the camera;
/// everything is projected with p = 1/d so scenery accelerates toward the viewer.
final class NeonRunnerSim {
    struct Row { var z: Double; var block: UInt8; var low: UInt8; var id: Int; var hue: Double }
    struct Orb { var z: Double; var lane: Int; var lift: Double; var taken: Bool }

    private let clock = LoopClock()
    private var rng = SplitMix64(seed: 0x5EED_0001)

    private var time = 0.0
    private var travelled = 0.0
    private var speed = 10.0
    private var rows: [Row] = []
    private var orbs: [Orb] = []
    private var spawnZ = 16.0
    private var nextRowID = 0

    private var lat = 0.0
    private var latVel = 0.0
    private var targetLane = 0
    private var switchCooldown = 0.0
    private var jumpT = -1.0
    private var jumpedRow = -1
    private let jumpDuration = 0.62

    private var orbCount = 0
    private var sparks = SparkPool(capacity: 80)

    private static let trailCount = 18
    private var trailLat = [Double](repeating: 0, count: trailCount)
    private var trailLift = [Double](repeating: 0, count: trailCount)
    private var trailTimer = 0.0

    private let runnerD = 1.5
    private let farD = 36.0

    init() {
        rows.reserveCapacity(16)
        orbs.reserveCapacity(96)
        while spawnZ < 40 { spawn(at: spawnZ) }
    }

    // MARK: Simulation

    private func spawn(at z: Double) {
        let r = rng.unit()
        var block: UInt8 = 0
        var low: UInt8 = 0
        if r < 0.30 {
            block = 1 << UInt8(rng.int(0, 2))
        } else if r < 0.50 {
            block = 7 & ~(1 << UInt8(rng.int(0, 2)))
        } else if r < 0.68 {
            low = 7
        } else if r < 0.80 {
            let l = rng.int(0, 2)
            low = 1 << UInt8(l)
            block = 1 << UInt8((l + 1 + rng.int(0, 1)) % 3)
        }
        if block | low != 0 {
            rows.append(Row(z: z, block: block, low: low, id: nextRowID, hue: rng.range(0.9, 1.08)))
            nextRowID += 1
        }

        if low != 0 {
            // Orb arc hovering over the barrier: rewards the jump.
            var lane = 0
            for l in 0..<3 where low & (1 << UInt8(l)) != 0 { lane = l; break }
            for i in 0..<5 {
                let f = Double(i) / 4
                orbs.append(Orb(z: z - 1.6 + f * 3.2, lane: lane - 1, lift: sin(f * .pi), taken: false))
            }
        } else if block != 0 {
            var free: [Int] = []
            for l in 0..<3 where block & (1 << UInt8(l)) == 0 { free.append(l) }
            let lane = free[rng.int(0, free.count - 1)] - 1
            for i in 0..<5 { orbs.append(Orb(z: z + 1.6 + Double(i) * 0.9, lane: lane, lift: 0, taken: false)) }
        } else {
            var lane = rng.int(-1, 1)
            for i in 0..<8 {
                if i == 4 { lane = clamp(lane + (rng.unit() < 0.5 ? -1 : 1), -1, 1) }
                orbs.append(Orb(z: z + Double(i) * 0.9, lane: lane, lift: 0, taken: false))
            }
        }
        spawnZ += rng.range(8.7, 11.5)
    }

    private func decideLane() {
        let nearEdge = runnerD - 0.35
        let horizon = runnerD + 7.4
        var unsafe: UInt8 = 0
        var nearUnsafe: UInt8 = 0
        for row in rows {
            let d = row.z - travelled
            if d < nearEdge { continue }
            if d > horizon { break }
            unsafe |= row.block
            if d < runnerD + 3.0 { nearUnsafe |= row.block }
        }
        var orbScore = SIMD3<Double>(repeating: 0)
        for orb in orbs where !orb.taken {
            let d = orb.z - travelled
            if d < runnerD - 0.2 { continue }
            if d > horizon + 1.5 { break }
            orbScore[orb.lane + 1] += 1
        }

        let cur = targetLane + 1
        let mustMove = unsafe & (1 << UInt8(cur)) != 0
        if !mustMove && switchCooldown > 0 { return }

        var best = cur
        var bestScore = mustMove ? -1e9 : orbScore[cur] + 1.4
        for l in 0..<3 where l != cur {
            if unsafe & (1 << UInt8(l)) != 0 { continue }
            // Every lane we sweep across must be clear of an imminent block.
            let lo = min(l, cur), hi = max(l, cur)
            var pathClear = true
            for m in (lo + 1)..<max(hi, lo + 1) where nearUnsafe & (1 << UInt8(m)) != 0 { pathClear = false }
            if !pathClear { continue }
            let s = orbScore[l] - 0.6 * Double(abs(l - cur))
            if s > bestScore { bestScore = s; best = l }
        }
        if best != cur {
            targetLane = best - 1
            switchCooldown = 0.55
        }
    }

    private func maybeJump() {
        guard jumpT < 0 else { return }
        let lead = speed * jumpDuration * 0.5
        for row in rows where row.low != 0 && row.id != jumpedRow {
            let d = row.z - travelled - runnerD
            if d < -0.3 { continue }
            if d > lead + 0.4 { break }
            if d <= lead {
                for l in 0..<3 where row.low & (1 << UInt8(l)) != 0 && abs(lat - Double(l - 1)) < 0.65 {
                    jumpT = 0
                    jumpedRow = row.id
                    return
                }
            }
        }
    }

    private func liftAmount() -> Double {
        guard jumpT >= 0 else { return 0 }
        return 4 * jumpT * (1 - jumpT) * 0.95
    }

    private func step(_ dt: Double) {
        time += dt
        speed = 10 + 1.4 * sin(time * 0.23) + min(time * 0.05, 2.0)
        travelled += speed * dt
        switchCooldown = max(0, switchCooldown - dt)

        while spawnZ < travelled + 40 { spawn(at: spawnZ) }
        while let f = rows.first, f.z < travelled - 1.2 { rows.removeFirst() }
        while let f = orbs.first, f.z < travelled - 1.2 { orbs.removeFirst() }

        decideLane()
        maybeJump()

        // Critically damped spring: smooth lane change with no overshoot.
        let k = 110.0, c = 2 * k.squareRoot()
        latVel += ((Double(targetLane) - lat) * k - latVel * c) * dt
        lat += latVel * dt
        if jumpT >= 0 {
            jumpT += dt / jumpDuration
            if jumpT >= 1 { jumpT = -1 }
        }

        // Collect orbs near the runner.
        let lift = liftAmount()
        for i in orbs.indices where !orbs[i].taken {
            let d = orbs[i].z - travelled
            if d > runnerD + 1 { break }
            if abs(d - runnerD) < 0.5 && abs(Double(orbs[i].lane) - lat) < 0.55 {
                orbs[i].taken = true
                orbCount += 1
                for _ in 0..<9 {
                    var s = Spark()
                    s.x = Double(orbs[i].lane)
                    s.y = 0.45 + orbs[i].lift * 0.9 + lift * 0.2
                    s.z = orbs[i].z
                    s.vx = rng.range(-1.6, 1.6)
                    s.vy = rng.range(-0.5, 2.2)
                    s.vz = rng.range(-1, 1)
                    s.life = rng.range(0.35, 0.6)
                    s.maxLife = s.life
                    s.hue = rng.range(0.1, 0.55)
                    sparks.emit(s)
                }
            }
        }
        sparks.step(dt, gravity: -3.5, drag: 1.5)

        trailTimer += dt
        if trailTimer >= 0.022 {
            trailTimer = 0
            for i in stride(from: Self.trailCount - 1, to: 0, by: -1) {
                trailLat[i] = trailLat[i - 1]
                trailLift[i] = trailLift[i - 1]
            }
            trailLat[0] = lat
            trailLift[0] = lift
        }
    }

    // MARK: Rendering

    private static let skyGradient = Gradient(stops: [
        .init(color: Neon.rgb(0.015, 0.0, 0.08), location: 0),
        .init(color: Neon.rgb(0.20, 0.02, 0.36), location: 0.55),
        .init(color: Neon.rgb(0.85, 0.12, 0.50), location: 0.9),
        .init(color: Neon.rgb(1.0, 0.45, 0.45), location: 1),
    ])
    private static let sunGradient = Gradient(colors: [
        Neon.rgb(1.0, 0.92, 0.35), Neon.rgb(1.0, 0.45, 0.35), Neon.rgb(0.95, 0.12, 0.62),
    ])
    private static let groundGradient = Gradient(colors: [
        Neon.rgb(0.20, 0.02, 0.26), Neon.rgb(0.05, 0.0, 0.12), Neon.rgb(0.015, 0.0, 0.05),
    ])
    private static let roadGradient = Gradient(colors: [
        Neon.rgb(0.10, 0.04, 0.22), Neon.rgb(0.03, 0.02, 0.10),
    ])

    func render(_ date: Date, _ ctx: inout GraphicsContext, _ size: CGSize) {
        let dt = clock.delta(date)
        if dt > 0 { step(dt) }

        let w = size.width, h = size.height
        guard w > 8, h > 8 else { return }
        let hy = h * 0.40
        let groundH = h - hy
        let laneW = min(w * 0.48, groundH * 0.95) / 1.5
        let cx = w / 2 - lat * laneW * 0.06
        let fullRect = CGRect(x: 0, y: 0, width: w, height: h)

        // Sky
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: hy + 1)),
                 with: .linearGradient(Self.skyGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: hy)))
        drawStars(&ctx, w: w, hy: hy)
        drawSun(&ctx, w: w, hy: hy, cx: cx)
        drawSkyline(&ctx, w: w, hy: hy, cx: cx)

        // Ground
        ctx.fill(Path(CGRect(x: 0, y: hy, width: w, height: groundH)),
                 with: .linearGradient(Self.groundGradient, startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: h)))

        // Side radial grid lines (outside the road).
        var rays = Path()
        for n in 0..<12 {
            let off = 1.5 + Double(n) * 1.1
            rays.move(to: CGPoint(x: cx, y: hy))
            rays.addLine(to: CGPoint(x: cx + off * laneW * 1.0, y: h))
            rays.move(to: CGPoint(x: cx, y: hy))
            rays.addLine(to: CGPoint(x: cx - off * laneW * 1.0, y: h))
        }
        ctx.stroke(rays, with: .color(Neon.rgb(0.9, 0.2, 0.9, 0.22)), lineWidth: 1)

        // Road surface
        var road = Path()
        road.move(to: CGPoint(x: cx, y: hy))
        road.addLine(to: CGPoint(x: cx + 1.5 * laneW, y: h))
        road.addLine(to: CGPoint(x: cx - 1.5 * laneW, y: h))
        road.closeSubpath()
        ctx.fill(road, with: .linearGradient(Self.roadGradient, startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: h)))

        // Scrolling speed bands + grid lines
        let spacing = 2.0
        var k = (travelled + 0.6) / spacing
        k = k.rounded(.up)
        var gridPath = Path()
        while true {
            let d = k * spacing - travelled
            if d > farD { break }
            let p = 1 / d
            let y = hy + groundH * p
            if Int(k) & 1 == 0 {
                let d2 = d + spacing
                let p2 = 1 / d2
                let y2 = hy + groundH * p2
                var band = Path()
                band.move(to: CGPoint(x: cx - 1.5 * laneW * p, y: y))
                band.addLine(to: CGPoint(x: cx + 1.5 * laneW * p, y: y))
                band.addLine(to: CGPoint(x: cx + 1.5 * laneW * p2, y: y2))
                band.addLine(to: CGPoint(x: cx - 1.5 * laneW * p2, y: y2))
                band.closeSubpath()
                ctx.fill(band, with: .color(Neon.rgb(0.6, 0.4, 1.0, 0.05 + 0.04 * min(1, p * 4))))
            }
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: w, y: y))
            k += 1
        }
        ctx.stroke(gridPath, with: .color(Neon.rgb(0.95, 0.3, 0.85, 0.30)), lineWidth: 1.2)

        // Horizon glow
        ctx.blendMode = .plusLighter
        ctx.fill(Path(CGRect(x: 0, y: hy - 2, width: w, height: 4)), with: .color(Neon.rgb(1, 0.4, 0.7, 0.9)))
        ctx.fill(Path(CGRect(x: 0, y: hy - 14, width: w, height: 28)), with: .linearGradient(
            Gradient(colors: [.clear, Neon.rgb(1, 0.3, 0.6, 0.25), .clear]),
            startPoint: CGPoint(x: 0, y: hy - 14), endPoint: CGPoint(x: 0, y: hy + 14)))

        // Lane dividers and edges
        var dividers = Path()
        var edges = Path()
        for off in [-0.5, 0.5] {
            dividers.move(to: CGPoint(x: cx, y: hy))
            dividers.addLine(to: CGPoint(x: cx + off * laneW, y: h))
        }
        for off in [-1.5, 1.5] {
            edges.move(to: CGPoint(x: cx, y: hy))
            edges.addLine(to: CGPoint(x: cx + off * laneW, y: h))
        }
        ctx.stroke(dividers, with: .color(Neon.rgb(0.3, 0.9, 1, 0.10)), lineWidth: 8)
        ctx.stroke(dividers, with: .color(Neon.rgb(0.5, 0.95, 1, 0.35)), lineWidth: 1.5)
        ctx.stroke(edges, with: .color(Neon.rgb(0.2, 0.8, 1, 0.12)), lineWidth: 14)
        ctx.stroke(edges, with: .color(Neon.rgb(0.2, 0.8, 1, 0.25)), lineWidth: 6)
        ctx.stroke(edges, with: .color(Neon.rgb(0.7, 0.97, 1, 0.95)), lineWidth: 2)
        // Racing dashes on the dividers sell the speed.
        let dashSpacing = 1.6
        var dk = ((travelled + 0.6) / dashSpacing).rounded(.up)
        while true {
            let d0 = dk * dashSpacing - travelled
            if d0 > farD * 0.8 { break }
            let d1 = d0 + 0.7
            let p0 = 1 / d0, p1 = 1 / d1
            let width = 1.5 + 3.5 * p0
            for off in [-0.5, 0.5] {
                var seg = Path()
                seg.move(to: CGPoint(x: cx + off * laneW * p0, y: hy + groundH * p0))
                seg.addLine(to: CGPoint(x: cx + off * laneW * p1, y: hy + groundH * p1))
                ctx.stroke(seg, with: .color(Neon.rgb(0.7, 0.98, 1, min(1, 0.4 + p0 * 3))), lineWidth: width)
            }
            dk += 1
        }
        ctx.blendMode = .normal

        // Pylons
        let pylonSpacing = 5.0
        var pk = ((travelled + 0.6) / pylonSpacing).rounded(.up)
        var pylons: [(Double, Int)] = []
        pylons.reserveCapacity(10)
        while true {
            let d = pk * pylonSpacing - travelled
            if d > farD { break }
            pylons.append((d, Int(pk)))
            pk += 1
        }
        for (d, idx) in pylons.reversed() {
            let p = 1 / d
            let hue = idx % 2 == 0 ? 0.5 : 0.88
            let alpha = 1 - smoothstep(farD * 0.7, farD, d)
            for side in [-1.0, 1.0] {
                let x = cx + side * 1.95 * laneW * p
                let y = hy + groundH * p
                let top = y - 1.6 * laneW * p
                var post = Path()
                post.move(to: CGPoint(x: x, y: y))
                post.addLine(to: CGPoint(x: x, y: top))
                ctx.stroke(post, with: .color(Neon.color(hue, a: 0.25 * alpha)), lineWidth: max(1, 0.12 * laneW * p))
                ctx.stroke(post, with: .color(Neon.color(hue, s: 0.4, a: 0.85 * alpha)), lineWidth: max(0.8, 0.035 * laneW * p))
                ctx.blendMode = .plusLighter
                let r = max(1.2, 0.09 * laneW * p)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2.2, y: top - r * 2.2, width: r * 4.4, height: r * 4.4)),
                         with: .color(Neon.color(hue, a: 0.25 * alpha)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: top - r, width: r * 2, height: r * 2)),
                         with: .color(Neon.color(hue, s: 0.3, a: alpha)))
                ctx.blendMode = .normal
            }
        }

        // Objects far -> near, with the runner slotted in at its depth.
        var ri = rows.count - 1
        var oi = orbs.count - 1
        var runnerDrawn = false
        while ri >= 0 || oi >= 0 {
            let rz = ri >= 0 ? rows[ri].z : -Double.infinity
            let oz = oi >= 0 ? orbs[oi].z : -Double.infinity
            let useRow = rz >= oz
            let z = useRow ? rz : oz
            let d = z - travelled
            if !runnerDrawn && d < runnerD {
                drawRunner(&ctx, hy: hy, groundH: groundH, laneW: laneW, cx: cx)
                runnerDrawn = true
            }
            if useRow {
                if d > 0.55 { drawRow(&ctx, rows[ri], d: d, hy: hy, groundH: groundH, laneW: laneW, cx: cx) }
                ri -= 1
            } else {
                if !orbs[oi].taken && d > 0.6 { drawOrb(&ctx, orbs[oi], d: d, hy: hy, groundH: groundH, laneW: laneW, cx: cx) }
                oi -= 1
            }
        }
        if !runnerDrawn { drawRunner(&ctx, hy: hy, groundH: groundH, laneW: laneW, cx: cx) }

        drawSparks(&ctx, hy: hy, groundH: groundH, laneW: laneW, cx: cx)

        // Vignette
        ctx.fill(Path(fullRect), with: .radialGradient(
            Gradient(colors: [.clear, Neon.rgb(0, 0, 0, 0.45)]),
            center: CGPoint(x: w / 2, y: h * 0.55), startRadius: min(w, h) * 0.5, endRadius: max(w, h) * 0.85))

        drawHUD(&ctx, w: w, h: h)
    }

    private func drawStars(_ ctx: inout GraphicsContext, w: Double, hy: Double) {
        for i in 0..<40 {
            let x = hash01(i * 3 + 1) * w
            let y = hash01(i * 3 + 2) * hy * 0.72
            let tw = 0.5 + 0.5 * sin(time * (1 + hash01(i) * 2) + Double(i))
            let s = 0.8 + hash01(i * 7) * 1.4
            ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(0.25 + 0.5 * tw)))
        }
    }

    private func drawSun(_ ctx: inout GraphicsContext, w: Double, hy: Double, cx: Double) {
        let r = min(w * 0.30, hy * 0.62)
        let cy = hy - r * 0.42
        let halo = Path(ellipseIn: CGRect(x: cx - r * 1.8, y: cy - r * 1.8, width: r * 3.6, height: r * 3.6))
        ctx.blendMode = .plusLighter
        ctx.fill(halo, with: .radialGradient(Gradient(colors: [Neon.rgb(1, 0.3, 0.6, 0.35), .clear]),
                                             center: CGPoint(x: cx, y: cy), startRadius: r * 0.8, endRadius: r * 1.8))
        ctx.blendMode = .normal
        ctx.drawLayer { l in
            l.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: hy)))
            l.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                   with: .linearGradient(Self.sunGradient, startPoint: CGPoint(x: 0, y: cy - r), endPoint: CGPoint(x: 0, y: cy + r)))
            l.blendMode = .destinationOut
            for i in 0..<7 {
                let f = fract(Double(i) / 7 + time * 0.06)
                let y = cy - r * 0.15 + r * 1.15 * f
                let th = r * (0.015 + 0.13 * f)
                l.fill(Path(CGRect(x: cx - r - 2, y: y, width: r * 2 + 4, height: th)), with: .color(.black))
            }
        }
    }

    private func drawSkyline(_ ctx: inout GraphicsContext, w: Double, hy: Double, cx: Double) {
        let n = 26
        let bw = w / Double(n)
        var skyline = Path()
        for i in 0..<n {
            let hh = hy * (0.025 + 0.11 * pow(hash01(i + 100), 2))
            skyline.addRect(CGRect(x: Double(i) * bw - 0.5, y: hy - hh, width: bw + 1, height: hh))
        }
        ctx.fill(skyline, with: .color(Neon.rgb(0.05, 0.0, 0.12)))
        var windows = Path()
        for i in 0..<n where hash01(i + 300) > 0.5 {
            let hh = hy * (0.025 + 0.11 * pow(hash01(i + 100), 2))
            windows.addRect(CGRect(x: Double(i) * bw + bw * 0.3, y: hy - hh * 0.7, width: max(1, bw * 0.12), height: max(1, hh * 0.1)))
        }
        ctx.fill(windows, with: .color(Neon.rgb(1, 0.6, 0.9, 0.6)))
    }

    private func laneX(_ lane: Double, p: Double, laneW: Double, cx: Double) -> Double { cx + lane * laneW * p }

    private func drawBox(_ ctx: inout GraphicsContext, lane: Int, d: Double, halfW: Double, height: Double,
                         depth: Double, hue: Double, alpha: Double, hy: Double, groundH: Double, laneW: Double, cx: Double) {
        let p = 1 / d, pb = 1 / (d + depth)
        let u = laneW * p, ub = laneW * pb
        let xc = laneX(Double(lane), p: p, laneW: laneW, cx: cx)
        let xb = laneX(Double(lane), p: pb, laneW: laneW, cx: cx)
        let y0 = hy + groundH * p, yb = hy + groundH * pb
        let front = CGRect(x: xc - halfW * u, y: y0 - height * u, width: halfW * 2 * u, height: height * u)
        var top = Path()
        top.move(to: CGPoint(x: xc - halfW * u, y: y0 - height * u))
        top.addLine(to: CGPoint(x: xc + halfW * u, y: y0 - height * u))
        top.addLine(to: CGPoint(x: xb + halfW * ub, y: yb - height * ub))
        top.addLine(to: CGPoint(x: xb - halfW * ub, y: yb - height * ub))
        top.closeSubpath()
        let frontPath = Path(roundedRect: front, cornerRadius: u * 0.05)

        ctx.fill(top, with: .color(Neon.color(hue, s: 0.8, b: 0.55, a: alpha)))
        ctx.fill(frontPath, with: .linearGradient(
            Gradient(colors: [Neon.color(hue, s: 0.9, b: 0.38, a: alpha), Neon.color(hue + 0.05, s: 0.95, b: 0.14, a: alpha)]),
            startPoint: CGPoint(x: 0, y: front.minY), endPoint: CGPoint(x: 0, y: front.maxY)))
        ctx.blendMode = .plusLighter
        ctx.stroke(frontPath, with: .color(Neon.color(hue, a: 0.18 * alpha)), lineWidth: max(2, u * 0.16))
        ctx.stroke(frontPath, with: .color(Neon.color(hue, s: 0.6, a: 0.95 * alpha)), lineWidth: max(1, u * 0.035))
        ctx.stroke(top, with: .color(Neon.color(hue, s: 0.5, a: 0.8 * alpha)), lineWidth: max(0.8, u * 0.025))
        var stripe = Path()
        stripe.move(to: CGPoint(x: front.minX + u * 0.05, y: front.minY + front.height * 0.45))
        stripe.addLine(to: CGPoint(x: front.maxX - u * 0.05, y: front.minY + front.height * 0.45))
        ctx.stroke(stripe, with: .color(Neon.color(hue + 0.08, s: 0.4, a: 0.7 * alpha)), lineWidth: max(0.8, u * 0.04))
        ctx.blendMode = .normal
    }

    private func drawRow(_ ctx: inout GraphicsContext, _ row: Row, d: Double, hy: Double, groundH: Double, laneW: Double, cx: Double) {
        let alpha = 1 - smoothstep(farD * 0.72, farD, d)
        for l in 0..<3 {
            let bit = UInt8(1) << UInt8(l)
            if row.block & bit != 0 {
                drawBox(&ctx, lane: l - 1, d: d, halfW: 0.40, height: 0.95, depth: 0.6, hue: row.hue,
                        alpha: alpha, hy: hy, groundH: groundH, laneW: laneW, cx: cx)
            } else if row.low & bit != 0 {
                drawBox(&ctx, lane: l - 1, d: d, halfW: 0.46, height: 0.34, depth: 0.3, hue: 0.12,
                        alpha: alpha, hy: hy, groundH: groundH, laneW: laneW, cx: cx)
            }
        }
    }

    private func drawOrb(_ ctx: inout GraphicsContext, _ orb: Orb, d: Double, hy: Double, groundH: Double, laneW: Double, cx: Double) {
        let p = 1 / d
        let u = laneW * p
        let alpha = 1 - smoothstep(farD * 0.72, farD, d)
        let x = laneX(Double(orb.lane), p: p, laneW: laneW, cx: cx)
        let bob = 0.05 * sin(time * 6 + orb.z * 2)
        let y = hy + groundH * p - (0.42 + orb.lift * 0.95 + bob) * u
        let r = max(1.0, 0.15 * u)
        ctx.blendMode = .plusLighter
        if r > 2 {
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 2.4, y: y - r * 2.4, width: r * 4.8, height: r * 4.8)),
                     with: .color(Neon.rgb(1, 0.8, 0.2, 0.16 * alpha)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r * 1.5, y: y - r * 1.5, width: r * 3, height: r * 3)),
                     with: .color(Neon.rgb(1, 0.75, 0.2, 0.3 * alpha)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [Neon.rgb(1, 1, 0.9, alpha), Neon.rgb(1, 0.7, 0.15, alpha)]),
                                       center: CGPoint(x: x - r * 0.2, y: y - r * 0.25), startRadius: 0, endRadius: r * 1.1))
        ctx.blendMode = .normal
    }

    private func drawRunner(_ ctx: inout GraphicsContext, hy: Double, groundH: Double, laneW: Double, cx: Double) {
        let p = 1 / runnerD
        let u = laneW * p
        let lift = liftAmount()
        let x = laneX(lat, p: p, laneW: laneW, cx: cx)
        let y0 = hy + groundH * p
        let bodyW = 0.44 * u, bodyH = 0.78 * u
        let centerY = y0 - (0.55 + lift) * u

        ctx.blendMode = .plusLighter
        // Ground light pool
        let poolW = u * 0.9 * (1 - 0.3 * lift), poolH = u * 0.22 * (1 - 0.3 * lift)
        ctx.fill(Path(ellipseIn: CGRect(x: x - poolW / 2, y: y0 - poolH / 2, width: poolW, height: poolH)),
                 with: .color(Neon.rgb(0.2, 0.9, 1, 0.35 * (1 - 0.6 * lift))))

        // Light trail
        let n = Self.trailCount
        var prev = CGPoint(x: x, y: centerY + bodyH * 0.25)
        for i in 0..<n {
            let f = Double(i + 1) / Double(n)
            let dd = runnerD - Double(i + 1) * 0.045
            if dd < 0.6 { break }
            let pp = 1 / dd
            let uu = laneW * pp
            let pt = CGPoint(x: laneX(trailLat[i], p: pp, laneW: laneW, cx: cx),
                             y: hy + groundH * pp - (0.3 + trailLift[i]) * uu)
            var seg = Path()
            seg.move(to: prev)
            seg.addLine(to: pt)
            let a = (1 - f) * (1 - f)
            ctx.stroke(seg, with: .color(Neon.color(0.5 + 0.4 * f, s: 0.9, a: 0.55 * a)), style: StrokeStyle(lineWidth: bodyW * 1.1 * (1 - f * 0.8), lineCap: .round))
            ctx.stroke(seg, with: .color(Neon.color(0.5 + 0.4 * f, s: 0.4, a: 0.9 * a)), style: StrokeStyle(lineWidth: bodyW * 0.35 * (1 - f * 0.8), lineCap: .round))
            prev = pt
        }

        var c = ctx
        c.translateBy(x: x, y: centerY)
        c.rotate(by: .radians(clamp(latVel * 0.045, -0.35, 0.35)))
        let body = CGRect(x: -bodyW / 2, y: -bodyH / 2, width: bodyW, height: bodyH)
        let capsule = Path(roundedRect: body, cornerRadius: bodyW / 2)
        c.stroke(capsule, with: .color(Neon.rgb(0.2, 0.9, 1, 0.12)), lineWidth: u * 0.34)
        c.stroke(capsule, with: .color(Neon.rgb(0.3, 0.95, 1, 0.25)), lineWidth: u * 0.18)
        c.blendMode = .normal
        c.fill(capsule, with: .linearGradient(
            Gradient(colors: [Neon.rgb(0.85, 1, 1), Neon.rgb(0.1, 0.75, 1), Neon.rgb(0.35, 0.2, 0.9)]),
            startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
        c.stroke(capsule, with: .color(.white.opacity(0.9)), lineWidth: max(1, u * 0.03))
        // Visor + core light
        let visor = CGRect(x: -bodyW * 0.32, y: -bodyH * 0.30, width: bodyW * 0.64, height: bodyH * 0.2)
        c.fill(Path(roundedRect: visor, cornerRadius: visor.height / 2), with: .color(Neon.rgb(0.05, 0.02, 0.2, 0.9)))
        c.blendMode = .plusLighter
        let eye = CGRect(x: -bodyW * 0.2, y: -bodyH * 0.25, width: bodyW * 0.4, height: bodyH * 0.07)
        c.fill(Path(roundedRect: eye, cornerRadius: eye.height / 2), with: .color(Neon.rgb(1, 0.4, 0.9)))
        let core = CGRect(x: -bodyW * 0.12, y: bodyH * 0.1, width: bodyW * 0.24, height: bodyW * 0.24)
        c.fill(Path(ellipseIn: core), with: .color(.white.opacity(0.85)))
    }

    private func drawSparks(_ ctx: inout GraphicsContext, hy: Double, groundH: Double, laneW: Double, cx: Double) {
        ctx.blendMode = .plusLighter
        for s in sparks.items where s.life > 0 {
            let d = s.z - travelled
            if d < 0.6 { continue }
            let p = 1 / d
            let u = laneW * p
            let f = s.life / s.maxLife
            let x = laneX(s.x, p: p, laneW: laneW, cx: cx)
            let y = hy + groundH * p - s.y * u
            let r = max(1, u * 0.07 * (0.4 + f))
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(Neon.color(s.hue, s: 0.5, a: f)))
        }
        ctx.blendMode = .normal
    }

    private func drawHUD(_ ctx: inout GraphicsContext, w: Double, h: Double) {
        let fs = clamp(min(w, h) * 0.07, 14, 64)
        let cxm = w / 2
        let top = max(6, fs * 0.4)
        drawText(&ctx, "SCORE", size: fs * 0.36, color: Neon.rgb(0.7, 0.95, 1, 0.75), at: CGPoint(x: cxm, y: top), anchor: .top, tracking: fs * 0.12)
        let score = Int(travelled * 4) + orbCount * 50
        let str = String(score)
        let pt = CGPoint(x: cxm, y: top + fs * 0.45)
        drawText(&ctx, str, size: fs, color: Neon.rgb(0.2, 0.9, 1, 0.35), at: CGPoint(x: pt.x, y: pt.y + 1.5), anchor: .top)
        drawText(&ctx, str, size: fs, color: Neon.rgb(1, 0.4, 0.9, 0.35), at: CGPoint(x: pt.x + 1.5, y: pt.y), anchor: .top)
        drawText(&ctx, str, size: fs, color: .white, at: pt, anchor: .top)
        drawText(&ctx, "\(orbCount) ORBS", size: fs * 0.34, color: Neon.rgb(1, 0.8, 0.3, 0.9),
                 at: CGPoint(x: cxm, y: pt.y + fs * 1.15), anchor: .top, tracking: fs * 0.08)
    }
}
