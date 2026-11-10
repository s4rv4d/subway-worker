import SwiftUI

struct RailRushView: View {
    let isPaused: Bool
    @State private var renderer = RailRushRenderer()

    var body: some View {
        LoopHost(isPaused: isPaused) { date, ctx, size in
            renderer.render(date, &ctx, size)
        }
    }
}

// MARK: - Schedule

/// The whole run is a pure function of time. Time is cut into fixed segments; each segment's
/// "safe" lane, trains, barriers and tokens come from an integer hash of its index, and the
/// runner's lane changes and jumps are read off that same schedule, so it always dodges.
///
/// Timing inside segment k (seconds after k * period):
///   0.15 ... ~0.66  runner eases from the previous safe lane to this one (every lane is clear)
///   0.95 ... ~2.12  trains in the other lanes meet the runner and pass the camera
///   0.94 ... 1.56   optional jump over a barrier in the safe lane
enum RailPlan {
    /// World units (one unit = one lane width) per second.
    static let speed = 11.0
    static let period = 2.3
    static let meetOffset = 0.95
    static let changeStart = 0.15
    static let barrierOffset = 1.25
    static let jumpDuration = 0.62
    static let jumpHeight = 0.85
    static let coinSpacing = 0.13
    static let carLength = 5.0
    static let carGap = 0.35
    /// Tokens per segment, cycled so the running total has a closed form.
    static let coinTable = [6, 0, 5, 8, 4, 7, 0, 6]
    static let coinTableSum = 36

    enum Kind { case none, parked, oncoming, barrier }

    struct Obstacle {
        var kind = Kind.none
        /// When its front reaches the runner's depth.
        var meet = 0.0
        var cars = 1
        /// Speed toward the runner (0 when parked).
        var trainSpeed = 0.0
        var palette = 0

        var length: Double { Double(cars) * RailPlan.carLength + Double(cars - 1) * RailPlan.carGap }
    }

    @inline(__always)
    static func h(_ k: Int, _ salt: Int) -> Double { hash01(k &* 64 &+ salt) }

    @inline(__always)
    static func segment(at t: Double) -> Int { Int((t / period).rounded(.down)) }

    static func safeLane(_ k: Int) -> Int { min(2, Int(h(k, 1) * 3)) - 1 }

    static func hasBarrier(_ k: Int) -> Bool {
        h(k, 2) < (safeLane(k) == safeLane(k - 1) ? 0.55 : 0.3)
    }

    static func changeDuration(_ lanes: Int) -> Double { 0.36 + 0.1 * Double(lanes) }

    static func obstacle(_ k: Int, lane: Int) -> Obstacle {
        let base = Double(k) * period
        let safe = safeLane(k), prev = safeLane(k - 1)
        if lane == safe {
            return hasBarrier(k) ? Obstacle(kind: .barrier, meet: base + barrierOffset) : Obstacle()
        }
        let r = h(k, 10 + lane + 1)
        var train: Bool
        var barrier = false
        if safe != prev {
            // The lane being left is always blocked: that's why the runner moves.
            if lane == prev { train = true } else { train = r < 0.45; barrier = !train && r < 0.72 }
        } else {
            // Staying put: keep one (or both) of the other lanes busy.
            let both = h(k, 5) < 0.4
            let first = safe == -1 ? 0 : -1
            let primary = h(k, 6) < 0.5 ? first : -(safe + first)
            train = both || lane == primary
            barrier = !train && r < 0.5
        }
        if barrier {
            return Obstacle(kind: .barrier, meet: base + 0.9 + 0.4 * h(k, 14 + lane))
        }
        guard train else { return Obstacle() }
        let kindRoll = h(k, 20 + lane + 1)
        let palette = Int(h(k, 24 + lane + 1) * 4) & 3
        if kindRoll < 0.42 {
            let cars = h(k, 28 + lane + 1) < 0.5 ? 1 : 2
            let stagger = cars == 1 ? 0.2 * h(k, 32 + lane + 1) : 0
            return Obstacle(kind: .parked, meet: base + meetOffset + stagger, cars: cars, palette: palette)
        }
        let cars = 1 + min(2, Int(h(k, 28 + lane + 1) * 3))
        return Obstacle(kind: .oncoming, meet: base + meetOffset + 0.25 * h(k, 32 + lane + 1),
                        cars: cars, trainSpeed: 5.5 + 3 * h(k, 36 + lane + 1), palette: palette)
    }

    /// Lateral position (in lanes) and lateral velocity of the runner.
    static func runnerX(_ t: Double) -> (x: Double, vel: Double) {
        let k = segment(at: t)
        let tau = t - Double(k) * period
        let s = safeLane(k), p = safeLane(k - 1)
        if s == p || tau <= changeStart { return (Double(p), 0) }
        let dur = changeDuration(abs(s - p))
        let u = (tau - changeStart) / dur
        if u >= 1 { return (Double(s), 0) }
        let e = u * u * (3 - 2 * u)
        return (Double(p) + Double(s - p) * e, Double(s - p) * 6 * u * (1 - u) / dur)
    }

    /// Jump progress 0...1 (or nil when grounded) for the segment containing t.
    static func jumpPhase(_ t: Double) -> Double? {
        let k = segment(at: t)
        guard hasBarrier(k) else { return nil }
        let start = Double(k) * period + barrierOffset - jumpDuration / 2
        let u = (t - start) / jumpDuration
        return u >= 0 && u < 1 ? u : nil
    }

    static func lift(_ t: Double) -> Double {
        guard let u = jumpPhase(t) else { return 0 }
        return 4 * u * (1 - u) * jumpHeight
    }

    /// Seconds since the last landing, if one happened in this segment.
    static func sinceLanding(_ t: Double) -> Double? {
        let k = segment(at: t)
        guard hasBarrier(k) else { return nil }
        let land = Double(k) * period + barrierOffset + jumpDuration / 2
        return t >= land ? t - land : nil
    }

    static func coinCount(_ k: Int) -> Int { coinTable[((k % 8) + 8) % 8] }

    /// Time the first token of segment k is collected.
    static func coinStart(_ k: Int) -> Double {
        let base = Double(k) * period
        let n = coinCount(k)
        if hasBarrier(k) { return base + barrierOffset - Double(n - 1) / 2 * coinSpacing }
        return base + 0.12 + 0.35 * h(k, 40)
    }

    /// Tokens collected by time t (closed form, no history needed).
    static func tokens(at t: Double) -> Int {
        let k = max(0, segment(at: t))
        var total = (k / 8) * coinTableSum
        for j in 0..<(k % 8) { total += coinTable[j] }
        let n = coinCount(k)
        if n > 0 {
            let start = coinStart(k)
            if t >= start { total += min(n, Int(((t - start) / coinSpacing).rounded(.down)) + 1) }
        }
        return total
    }
}

// MARK: - Rendering helpers

private typealias RGB = SIMD3<Double>

private func hex(_ v: UInt32) -> RGB {
    RGB(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
}

@inline(__always)
private func col(_ c: RGB, _ a: Double = 1) -> Color { Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: a) }

@inline(__always)
private func mixc(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * t }

/// Pseudo-3D projection: depth d is measured from the camera, p = cam.p(d).
/// The camera sits `back` lanes behind the runner with a long lens (`focal`), which keeps the
/// runner's size but makes the mid-ground (and the trains in it) read much bigger.
private struct Cam {
    static let back = 2.25
    static let focal = (RailRushRenderer.runnerD + back) / RailRushRenderer.runnerD
    var cx: Double, hy: Double, g: Double, lw: Double, camX: Double
    @inline(__always) func p(_ d: Double) -> Double { Self.focal / max(0.05, d + Self.back) }
    @inline(__always) func x(_ X: Double, _ p: Double) -> Double { cx + (X - camX) * lw * p }
    @inline(__always) func y(_ Y: Double, _ p: Double) -> Double { hy + (g - Y * lw) * p }
    @inline(__always) func pt(_ X: Double, _ Y: Double, _ p: Double) -> CGPoint { CGPoint(x: x(X, p), y: y(Y, p)) }
}

private enum Pal {
    static let haze = hex(0xC97E7E)
    static let ink = hex(0x1A1426)
    static let gold = hex(0xFFD24A)
    static let backpack = hex(0xFCCC0A)
    static let hoodie = hex(0x1E7C82)
    static let hoodieDark = hex(0x155A61)
    static let pants = hex(0x2B2E3B)
    static let sneaker = hex(0xF1ECE3)
    /// Train liveries: body, stripe. Plain commuter colours.
    static let trainBody: [RGB] = [hex(0xDCE5E2), hex(0x35507F), hex(0xC4573F), hex(0x9AA3B8)]
    static let trainStripe: [RGB] = [hex(0xE2583A), hex(0xEFD9A6), hex(0xF4E7CF), hex(0x2F8F8A)]
    static let graffiti: [RGB] = [hex(0xFF4FA3), hex(0x3ED6E8), hex(0xA6E22E), hex(0xFF8A3D), hex(0x9B5DE5), hex(0xFFD23F)]
}

/// One thing to paint in depth order (far first).
private struct Item {
    enum Kind: UInt8 { case train, barrier, coin, pop, pole, runner }
    var kind: Kind
    var key: Double
    var x = 0.0
    var d0 = 0.0
    var d1 = 0.0
    var aux = 0.0
    var y = 0.0
    var code = 0
}

// MARK: - Renderer

/// Draws Rail Rush. All state is derived from `time`; the only stored data is a reused scratch
/// buffer for depth sorting, so frames never allocate large arrays.
final class RailRushRenderer {
    /// Start a few seconds in so the very first (and paused-thumbnail) frame already has action.
    static let startTime = 7.7
    static let runnerD = 1.354
    static let farD = 75.0
    static let nearD = 0.35 - Cam.back

    private let clock = LoopClock()
    private var elapsed = 0.0
    private var items: [Item] = []

    init() { items.reserveCapacity(96) }

    func render(_ date: Date, _ ctx: inout GraphicsContext, _ size: CGSize) {
        elapsed += clock.delta(date)
        draw(&ctx, size: size, time: Self.startTime + elapsed)
    }

    private static let skyGradient = Gradient(stops: [
        .init(color: col(hex(0x141238)), location: 0),
        .init(color: col(hex(0x2C2363)), location: 0.34),
        .init(color: col(hex(0x683478)), location: 0.6),
        .init(color: col(hex(0xCF5878)), location: 0.8),
        .init(color: col(hex(0xF4895C)), location: 0.92),
        .init(color: col(hex(0xFFB66A)), location: 1),
    ])
    private static let groundGradient = Gradient(stops: [
        .init(color: col(hex(0x9A6670)), location: 0),
        .init(color: col(hex(0x5E4250)), location: 0.18),
        .init(color: col(hex(0x3A2A34)), location: 0.55),
        .init(color: col(hex(0x1E161D)), location: 1),
    ])
    private static let sunGradient = Gradient(colors: [col(hex(0xFFF0C2)), col(hex(0xFFC27A)), col(hex(0xFF9466))])
    private static let railGradient = Gradient(stops: [
        .init(color: col(hex(0xE7A79A), 0.45), location: 0),
        .init(color: col(hex(0xF2C9B4), 0.95), location: 0.3),
        .init(color: col(hex(0xA897A6), 0.9), location: 1),
    ])

    func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, h = size.height
        guard w > 8, h > 8 else { return }
        let hy = (h * 0.34).rounded()
        let g = h - hy
        let lw = min(w * 0.31, g * 0.62)
        let rx = RailPlan.runnerX(t)
        let cam = Cam(cx: w / 2, hy: hy, g: g, lw: lw, camX: rx.x * 0.4)
        let s = RailPlan.speed * t

        drawSky(&ctx, cam, w: w, t: t)
        drawGround(&ctx, cam, w: w, h: h, s: s)
        drawYard(&ctx, cam, s: s)
        drawWalls(&ctx, cam, w: w, s: s)
        collectItems(cam, t: t, s: s)
        for item in items { drawItem(&ctx, cam, item, t: t, runnerX: rx) }
        drawWires(&ctx, cam)

        // Soft vignette keeps the eye on the runner.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .radialGradient(
            Gradient(colors: [.clear, col(Pal.ink, 0.42)]),
            center: CGPoint(x: w / 2, y: h * 0.6), startRadius: min(w, h) * 0.45, endRadius: max(w, h) * 0.9))
        drawHUD(&ctx, w: w, h: h, t: t)
    }

    @inline(__always)
    private func fog(_ d: Double) -> Double { 0.88 * smoothstep(7, Self.farD, d) }
}

// MARK: Sky and skyline

extension RailRushRenderer {
    fileprivate func drawSky(_ ctx: inout GraphicsContext, _ cam: Cam, w: Double, t: Double) {
        let hy = cam.hy
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: hy + 1)),
                 with: .linearGradient(Self.skyGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: hy)))

        // A few early stars in the indigo.
        var stars = Path()
        let starSize = max(0.8, hy * 0.006)
        for i in 0..<26 {
            let x = hash01(i * 3 + 501) * w
            let y = hash01(i * 3 + 502) * hy * 0.42
            let tw = 0.5 + 0.5 * sin(t * (0.8 + hash01(i + 77) * 1.6) + Double(i))
            if tw < 0.35 { continue }
            stars.addEllipse(in: CGRect(x: x, y: y, width: starSize, height: starSize))
        }
        ctx.fill(stars, with: .color(.white.opacity(0.55)))

        // Low sun with a warm halo.
        let r = min(w * 0.13, hy * 0.34)
        let sx = w * 0.66 - cam.camX * cam.lw * 0.03, sy = hy - r * 0.28
        ctx.fill(Path(ellipseIn: CGRect(x: sx - r * 3.4, y: sy - r * 3.4, width: r * 6.8, height: r * 6.8)),
                 with: .radialGradient(Gradient(colors: [col(hex(0xFFB37A), 0.42), col(hex(0xFF8A6A), 0.0)]),
                                       center: CGPoint(x: sx, y: sy), startRadius: r * 0.8, endRadius: r * 3.4))
        ctx.fill(Path(ellipseIn: CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)),
                 with: .linearGradient(Self.sunGradient, startPoint: CGPoint(x: 0, y: sy - r), endPoint: CGPoint(x: 0, y: sy + r)))

        // Long flat clouds drifting slowly across the dusk.
        for i in 0..<4 {
            let cw = w * (0.22 + 0.25 * hash01(i + 610))
            let ch = max(1.5, hy * (0.018 + 0.02 * hash01(i + 620)))
            let span = w + cw
            let x = fract(hash01(i + 630) + t * (0.004 + 0.004 * hash01(i + 640))) * span - cw
            let y = hy * (0.32 + 0.42 * hash01(i + 650))
            let c = i % 2 == 0 ? hex(0xF59AA0) : hex(0xB06A9C)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: cw, height: ch), cornerRadius: ch / 2),
                     with: .color(col(c, 0.32)))
            ctx.fill(Path(roundedRect: CGRect(x: x + cw * 0.2, y: y + ch * 1.4, width: cw * 0.55, height: ch * 0.7),
                          cornerRadius: ch / 2), with: .color(col(c, 0.22)))
        }

        drawSkyline(&ctx, cam, w: w)
    }

    private func drawSkyline(_ ctx: inout GraphicsContext, _ cam: Cam, w: Double) {
        let hy = cam.hy
        let unit = max(5, hy * 0.11)
        let shift = -cam.camX * cam.lw * 0.04
        let n = Int(w / unit) + 3

        // Far layer: hazy violet blocks plus a construction crane.
        var far = Path()
        for i in 0..<n {
            let bw = unit * (0.8 + 0.6 * hash01(i + 700))
            let x = Double(i) * unit - unit + shift + (hash01(i + 710) - 0.5) * unit * 0.4
            let bh = hy * (0.07 + 0.16 * pow(hash01(i + 720), 1.6))
            far.addRect(CGRect(x: x, y: hy - bh, width: bw, height: bh + 1))
        }
        let craneX = w * 0.22 + shift, craneH = hy * 0.36, lineW = max(0.8, hy * 0.008)
        far.addRect(CGRect(x: craneX, y: hy - craneH, width: lineW * 1.6, height: craneH))
        far.addRect(CGRect(x: craneX - craneH * 0.25, y: hy - craneH, width: craneH * 0.85, height: lineW * 1.4))
        far.addRect(CGRect(x: craneX + craneH * 0.42, y: hy - craneH, width: lineW * 0.6, height: craneH * 0.25))
        ctx.fill(far, with: .color(col(hex(0x6A3E78), 0.78)))

        // Near layer: darker blocks with a few warm windows.
        var near = Path()
        var windows = Path()
        let win = max(0.8, unit * 0.11)
        for i in 0..<n {
            let bw = unit * (0.7 + 0.7 * hash01(i + 800))
            let x = Double(i) * unit - unit * 0.5 + shift * 1.6 + (hash01(i + 810) - 0.5) * unit * 0.5
            let bh = hy * (0.035 + 0.1 * pow(hash01(i + 820), 1.4))
            near.addRect(CGRect(x: x, y: hy - bh, width: bw, height: bh + 1))
            guard hash01(i + 830) > 0.45, bh > win * 4 else { continue }
            for j in 0..<3 where hash01(i * 7 + j + 840) > 0.35 {
                windows.addRect(CGRect(x: x + bw * (0.2 + 0.25 * Double(j)), y: hy - bh * (0.75 - 0.18 * Double(j % 2)),
                                       width: win, height: win * 1.3))
            }
        }
        ctx.fill(near, with: .color(col(hex(0x30214A))))
        ctx.fill(windows, with: .color(col(hex(0xFFC46B), 0.75)))
    }
}

// MARK: Ground, tracks, walls

extension RailRushRenderer {
    /// Ground-level strip between two lateral positions, from the vanishing point to the near plane.
    fileprivate func strip(_ cam: Cam, _ x1: Double, _ x2: Double, Y: Double = 0) -> Path {
        let pn = cam.p(Self.nearD)
        var path = Path()
        path.move(to: cam.pt(x1, Y, 0))
        path.addLine(to: cam.pt(x1, Y, pn))
        path.addLine(to: cam.pt(x2, Y, pn))
        path.addLine(to: cam.pt(x2, Y, 0))
        path.closeSubpath()
        return path
    }

    fileprivate func drawGround(_ ctx: inout GraphicsContext, _ cam: Cam, w: Double, h: Double, s: Double) {
        let hy = cam.hy
        ctx.fill(Path(CGRect(x: 0, y: hy, width: w, height: h - hy)),
                 with: .linearGradient(Self.groundGradient, startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: h)))

        // Dirt shoulders outside the tracks and darker ballast beds under each track.
        var shoulders = strip(cam, -2.55, -1.6)
        shoulders.addPath(strip(cam, 1.6, 2.55))
        ctx.fill(shoulders, with: .color(col(hex(0x24171F), 0.35)))
        // Light gravel across the yard, then a darker ballast bed under each of the three tracks.
        ctx.fill(strip(cam, -1.62, 1.62), with: .linearGradient(
            Gradient(colors: [col(hex(0xA87A80), 0.55), col(hex(0x6E5260)), col(hex(0x4A3844))]),
            startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: h)))
        var beds = Path()
        for lane in -1...1 { beds.addPath(strip(cam, Double(lane) - 0.45, Double(lane) + 0.45)) }
        ctx.fill(beds, with: .linearGradient(Gradient(colors: [col(hex(0x5A3E4A), 0.5), col(hex(0x2E2029)), col(hex(0x22171F))]),
                                             startPoint: CGPoint(x: 0, y: hy), endPoint: CGPoint(x: 0, y: h)))

        // Sleepers stream toward the camera; nearer ones are darker and crisper.
        let spacing = 0.34, depth = 0.13
        var nearTies = Path(), midTies = Path(), farTies = Path()
        var i = ((s - Self.runnerD + Self.nearD) / spacing).rounded(.up)
        while true {
            let d = i * spacing - s + Self.runnerD
            if d > 34 { break }
            let p0 = cam.p(d), p1 = cam.p(d + depth)
            for lane in -1...1 {
                let l = Double(lane)
                var q = Path()
                q.move(to: cam.pt(l - 0.38, 0, p0))
                q.addLine(to: cam.pt(l + 0.38, 0, p0))
                q.addLine(to: cam.pt(l + 0.38, 0, p1))
                q.addLine(to: cam.pt(l - 0.38, 0, p1))
                q.closeSubpath()
                if d < 10 { nearTies.addPath(q) } else if d < 20 { midTies.addPath(q) } else { farTies.addPath(q) }
            }
            i += 1
        }
        ctx.fill(farTies, with: .color(col(mixc(hex(0x7A5444), Pal.haze, 0.45), 0.35)))
        ctx.fill(midTies, with: .color(col(mixc(hex(0x7A5444), Pal.haze, 0.25), 0.7)))
        ctx.fill(nearTies, with: .color(col(hex(0x7A5242))))

        // Gravel speckles stream past for extra speed.
        var light = Path(), dark = Path()
        let cell = 0.5
        var ci = ((s - Self.runnerD + 0.6) / cell).rounded(.up)
        while true {
            let d = ci * cell - s + Self.runnerD
            if d > 16 { break }
            let p = cam.p(d)
            let sz = max(0.7, 0.022 * cam.lw * p)
            for k in 0..<5 {
                let seed = Int(ci) &* 8 &+ k
                let X = -1.6 + 3.2 * hash01(seed &+ 9000)
                let dz = cell * hash01(seed &+ 9100)
                let pp = cam.p(d + dz)
                let rect = CGRect(x: cam.x(X, pp) - sz / 2, y: cam.y(0, pp) - sz * 0.3, width: sz * 1.4, height: sz * 0.6)
                if k & 1 == 0 { light.addRect(rect) } else { dark.addRect(rect) }
            }
            ci += 1
        }
        ctx.fill(light, with: .color(col(hex(0xB08A8C), 0.35)))
        ctx.fill(dark, with: .color(col(hex(0x140C12), 0.35)))

        // Rails: a dark foot plus a bright top that catches the sunset.
        var railBase = Path(), railTop = Path()
        for lane in -1...1 {
            for side in [-0.245, 0.245] {
                let x = Double(lane) + side
                railBase.addPath(strip(cam, x - 0.04, x + 0.04))
                railTop.addPath(strip(cam, x - 0.016, x + 0.016, Y: 0.06))
            }
        }
        ctx.fill(railBase, with: .color(col(hex(0x1C141B), 0.9)))
        ctx.fill(railTop, with: .linearGradient(Self.railGradient, startPoint: CGPoint(x: 0, y: hy),
                                                endPoint: CGPoint(x: 0, y: h)))

        // Atmospheric haze where the yard meets the sky.
        let band = max(4, (h - hy) * 0.16)
        ctx.fill(Path(CGRect(x: 0, y: hy - band * 0.35, width: w, height: band * 1.35)), with: .linearGradient(
            Gradient(colors: [col(Pal.haze, 0), col(hex(0xE59A86), 0.55), col(Pal.haze, 0)]),
            startPoint: CGPoint(x: 0, y: hy - band * 0.35), endPoint: CGPoint(x: 0, y: hy + band)))
    }

    fileprivate func drawWalls(_ ctx: inout GraphicsContext, _ cam: Cam, w: Double, s: Double) {
        let top = 1.2
        let panel = 3.2
        for side in [-1.0, 1.0] {
            let xw = side * 2.55
            let base = side < 0 ? hex(0x7A5B70) : hex(0x6B5172)
            let nearX = cam.x(xw, 1.2)
            ctx.fill(Path.wallBand(cam, xw, 0, top), with: .linearGradient(
                Gradient(stops: [.init(color: col(base), location: 0), .init(color: col(mixc(base, Pal.haze, 0.55)), location: 0.75),
                                 .init(color: col(Pal.haze), location: 1)]),
                startPoint: CGPoint(x: nearX, y: 0), endPoint: CGPoint(x: cam.cx, y: 0)))
            // Grime along the bottom and two cast grooves.
            ctx.fill(Path.wallBand(cam, xw, 0, 0.2), with: .color(col(hex(0x24182A), 0.4)))
            var grooves = Path()
            for gy in [0.42, 0.82] {
                grooves.move(to: cam.pt(xw, gy, 0))
                grooves.addLine(to: cam.pt(xw, gy, cam.p(Self.nearD)))
            }
            ctx.stroke(grooves, with: .color(col(hex(0x2A1D30), 0.35)), lineWidth: max(0.6, cam.lw * 0.008))

            // Panel joints scroll past; each panel carries its own abstract graffiti, clipped to the
            // wall face so nothing can ever spill past it.
            var art = ctx
            art.clip(to: Path.wallBand(cam, xw, 0.02, top - 0.09))
            var joints = Path()
            var j = ((s - Self.runnerD + Self.nearD - panel) / panel).rounded(.up)
            while true {
                let d = j * panel - s + Self.runnerD
                if d > Self.farD { break }
                if d > Self.nearD {
                    let p0 = cam.p(d), p1 = cam.p(d + 0.08)
                    joints.move(to: cam.pt(xw, 0, p0))
                    joints.addLine(to: cam.pt(xw, top, p0))
                    joints.addLine(to: cam.pt(xw, top, p1))
                    joints.addLine(to: cam.pt(xw, 0, p1))
                    joints.closeSubpath()
                }
                if d < 44 && d + panel > Self.nearD + 0.4 {
                    drawGraffiti(&art, cam, xw: xw, panelD: d, seed: Int(j) &* 2 &+ (side > 0 ? 1 : 0))
                }
                j += 1
            }
            ctx.fill(joints, with: .color(col(hex(0x22172A), 0.5)))

            // Lit coping along the top edge.
            ctx.fill(Path.wallBand(cam, xw, top - 0.09, top), with: .color(col(hex(0xC3949C))))
            var cap = Path()
            cap.move(to: cam.pt(xw, top, 0))
            cap.addLine(to: cam.pt(xw, top, cam.p(Self.nearD)))
            cap.addLine(to: cam.pt(xw + side * 0.16, top, cam.p(Self.nearD)))
            cap.addLine(to: cam.pt(xw + side * 0.16, top, 0))
            cap.closeSubpath()
            ctx.fill(cap, with: .color(col(hex(0x9E7586))))
        }
    }

    fileprivate func drawWires(_ ctx: inout GraphicsContext, _ cam: Cam) {
        var wires = Path()
        for side in [-1.0, 1.0] {
            for (x, y) in [(1.25, 2.2), (1.3, 2.62)] {
                wires.move(to: cam.pt(side * x, y, 0))
                wires.addLine(to: cam.pt(side * x, y, cam.p(Self.nearD)))
            }
        }
        ctx.stroke(wires, with: .color(col(hex(0x22182C), 0.8)), lineWidth: max(0.7, cam.lw * 0.007))
    }
}

extension Path {
    /// Wall face between two heights on the plane X = xw.
    fileprivate static func wallBand(_ cam: Cam, _ xw: Double, _ y0: Double, _ y1: Double) -> Path {
        let pn = cam.p(RailRushRenderer.nearD)
        var path = Path()
        path.move(to: cam.pt(xw, y0, 0))
        path.addLine(to: cam.pt(xw, y0, pn))
        path.addLine(to: cam.pt(xw, y1, pn))
        path.addLine(to: cam.pt(xw, y1, 0))
        path.closeSubpath()
        return path
    }
}

// MARK: Graffiti

extension RailRushRenderer {
    /// Abstract graffiti on one wall panel. Shapes are built in wall coordinates (u along the
    /// track from the panel start, v up) and every vertex is projected exactly, so pieces stay
    /// glued to the wall even right next to the camera.
    fileprivate func drawGraffiti(_ ctx: inout GraphicsContext, _ cam: Cam, xw: Double, panelD: Double, seed: Int) {
        @inline(__always) func r(_ salt: Int) -> Double { hash01(seed &* 32 &+ 4000 &+ salt) }
        @inline(__always) func P(_ u: Double, _ v: Double) -> CGPoint { cam.pt(xw, v, cam.p(panelD + u)) }
        func circle(_ path: inout Path, _ cu: Double, _ cv: Double, _ ru: Double, _ rv: Double, _ n: Int = 14) {
            for i in 0..<n {
                let a = Double(i) / Double(n) * 2 * .pi
                let q = P(cu + ru * cos(a), cv + rv * sin(a))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
        }
        if r(0) < 0.08 { return }
        let fogK = fog(panelD + 1.6) * 0.8
        let fade = 1 - smoothstep(30, 44, panelD)
        let ci = Int(r(1) * 6) % 6
        let c1 = mixc(Pal.graffiti[ci], Pal.haze, fogK)
        let c2 = mixc(Pal.graffiti[(ci + 2 + Int(r(2) * 3)) % 6], Pal.haze, fogK)
        let c3 = mixc(Pal.graffiti[(ci + 1 + Int(r(3) * 4)) % 6], Pal.haze, fogK)
        let ink = col(Pal.ink, 0.85 * fade)
        let detail = cam.lw * cam.p(panelD + 1.6) > 7

        // Main piece: a bubbly blob cluster with drips, or a fat zigzag bolt.
        let width = 0.75 + 0.4 * r(6)
        let mainU = 1.6 + (r(4) - 0.5) * 0.4
        let mainV = 0.6 + (r(5) - 0.5) * 0.1
        if panelD + mainU - 0.8 * width > Self.nearD + 0.05 {
            if r(7) < 0.62 {
                var outline = Path(), body = Path(), shine = Path(), drips = Path(), dots = Path()
                let n = 3 + Int(r(8) * 3)
                var lowest = 0.0
                for i in 0..<n {
                    let f = Double(i) / Double(n - 1) - 0.5
                    let cu = mainU + f * 1.3 * width + (r(10 + i) - 0.5) * 0.12
                    let cv = mainV + (r(20 + i) - 0.5) * 0.16
                    let rad = 0.16 + 0.1 * r(30 + i)
                    lowest = min(lowest, cv - rad - mainV)
                    circle(&outline, cu, cv, rad + 0.045, rad + 0.045)
                    circle(&body, cu, cv, rad, rad)
                    if detail { circle(&shine, cu - rad * 0.3, cv + rad * 0.42, rad * 0.26, rad * 0.14, 8) }
                }
                if detail {
                    for i in 0..<(2 + Int(r(9) * 2)) {
                        let u = mainU + (r(40 + i) - 0.5) * width
                        let len = 0.12 + 0.24 * r(45 + i)
                        let v0 = mainV - 0.1
                        drips.move(to: P(u, v0))
                        drips.addLine(to: P(u, v0 - len))
                        circle(&dots, u, v0 - len - 0.02, 0.035, 0.035, 8)
                    }
                }
                ctx.fill(outline, with: .color(ink))
                ctx.stroke(drips, with: .color(col(c1, fade)),
                           style: StrokeStyle(lineWidth: max(0.5, 0.05 * cam.lw * cam.p(panelD + mainU)), lineCap: .round))
                ctx.fill(dots, with: .color(col(c1, fade)))
                let top = P(mainU, mainV + 0.3), bottom = P(mainU, mainV - 0.3)
                ctx.fill(body, with: .linearGradient(Gradient(colors: [col(c1, fade), col(c2, fade)]), startPoint: top, endPoint: bottom))
                ctx.fill(shine, with: .color(.white.opacity(0.5 * fade)))
            } else {
                // Marker-style ribbon: offset the zigzag vertically for a chisel-tip look.
                let n = 6
                func ribbon(_ hw: Double) -> Path {
                    var path = Path()
                    for i in 0..<(2 * n) {
                        let j = i < n ? i : 2 * n - 1 - i
                        let u = mainU + (Double(j) / Double(n - 1) - 0.5) * 1.5 * width
                        let v = mainV + (j % 2 == 0 ? 0.15 : -0.15) + (r(50 + j) - 0.5) * 0.06 + (i < n ? hw : -hw)
                        if i == 0 { path.move(to: P(u, v)) } else { path.addLine(to: P(u, v)) }
                    }
                    path.closeSubpath()
                    return path
                }
                ctx.fill(ribbon(0.11), with: .color(ink))
                ctx.fill(ribbon(0.065), with: .color(col(c1, fade)))
                if detail { ctx.fill(ribbon(0.018), with: .color(col(c2, 0.85 * fade))) }
            }
        }

        // Accent: a star or a ring near one end of the panel.
        guard r(60) < 0.85 else { return }
        let au = r(61) < 0.5 ? 0.45 : 2.75, av = r(62) < 0.5 ? 0.9 : 0.34
        guard panelD + au - 0.25 > Self.nearD + 0.05 else { return }
        if r(63) < 0.55 {
            var star = Path(), outline = Path()
            let outer = 0.13 + 0.05 * r(64), rot = r(65) * .pi
            for (path, grow) in [(0, 0.05), (1, 0.0)] {
                var s = Path()
                for i in 0..<10 {
                    let a = rot + Double(i) * .pi / 5
                    let rad = (i % 2 == 0 ? outer : outer * 0.45) + grow
                    let q = P(au + cos(a) * rad, av + sin(a) * rad)
                    if i == 0 { s.move(to: q) } else { s.addLine(to: q) }
                }
                s.closeSubpath()
                if path == 0 { outline = s } else { star = s }
            }
            ctx.fill(outline, with: .color(ink))
            ctx.fill(star, with: .color(col(c3, fade)))
        } else {
            let rad = 0.13 + 0.05 * r(66)
            var ring = Path(), inner = Path(), dot = Path()
            circle(&ring, au, av, rad + 0.05, rad + 0.05)
            circle(&ring, au, av, rad - 0.05, rad - 0.05)
            circle(&inner, au, av, rad + 0.025, rad + 0.025)
            circle(&inner, au, av, rad - 0.025, rad - 0.025)
            circle(&dot, au, av, 0.04, 0.04, 8)
            ctx.fill(ring, with: .color(ink), style: FillStyle(eoFill: true))
            ctx.fill(inner, with: .color(col(c3, fade)), style: FillStyle(eoFill: true))
            ctx.fill(dot, with: .color(col(c2, fade)))
        }
    }
}

// MARK: Objects

extension RailRushRenderer {
    fileprivate func collectItems(_ cam: Cam, t: Double, s: Double) {
        items.removeAll(keepingCapacity: true)
        let rD = Self.runnerD, far = Self.farD, near = Self.nearD
        let v = RailPlan.speed
        let kNow = RailPlan.segment(at: t)
        for k in (kNow - 1)...(kNow + 4) {
            for lane in -1...1 {
                let o = RailPlan.obstacle(k, lane: lane)
                switch o.kind {
                case .none:
                    break
                case .barrier:
                    let d = v * (o.meet - t) + rD
                    if d > near && d < far { items.append(Item(kind: .barrier, key: d, x: Double(lane), d0: d)) }
                case .parked, .oncoming:
                    let front = (v + o.trainSpeed) * (o.meet - t) + rD
                    let back = front + o.length
                    if back < near + 0.05 || front > far { continue }
                    let code = o.palette | (o.cars << 4) | (o.kind == .oncoming ? 256 : 0)
                    if front < rD && back > rD {
                        // Split at the runner's depth so the far half sits behind it and the near half in front.
                        items.append(Item(kind: .train, key: rD + 0.001, x: Double(lane), d0: rD, d1: back, aux: front, code: code))
                        items.append(Item(kind: .train, key: front, x: Double(lane), d0: max(front, near), d1: rD, aux: front, code: code))
                    } else {
                        items.append(Item(kind: .train, key: front, x: Double(lane), d0: max(front, near), d1: back, aux: front, code: code))
                    }
                }
            }
            // Tokens sit exactly on the runner's future path, so every one gets collected.
            let n = RailPlan.coinCount(k)
            guard n > 0 else { continue }
            let start = RailPlan.coinStart(k)
            for i in 0..<n {
                let tc = start + Double(i) * RailPlan.coinSpacing
                if tc > t {
                    let d = v * (tc - t) + rD
                    if d < far {
                        items.append(Item(kind: .coin, key: d, x: RailPlan.runnerX(tc).x, d0: d, aux: tc, y: 0.5 + RailPlan.lift(tc)))
                    }
                } else if t - tc < 0.25 {
                    items.append(Item(kind: .pop, key: 0, x: RailPlan.runnerX(tc).x, aux: t - tc, y: 0.5 + RailPlan.lift(tc), code: i))
                }
            }
        }
        let spacing = 8.0
        var j = ((s - rD + near) / spacing).rounded(.up)
        while true {
            let d = j * spacing - s + rD
            if d > far { break }
            items.append(Item(kind: .pole, key: d, d0: d))
            j += 1
        }
        items.append(Item(kind: .runner, key: rD))

        // Insertion sort, far to near: the list is short and nearly sorted already.
        if items.count > 1 {
            for i in 1..<items.count {
                let it = items[i]
                var j = i - 1
                while j >= 0 && items[j].key < it.key {
                    items[j + 1] = items[j]
                    j -= 1
                }
                items[j + 1] = it
            }
        }
    }

    fileprivate func drawItem(_ ctx: inout GraphicsContext, _ cam: Cam, _ item: Item, t: Double, runnerX: (x: Double, vel: Double)) {
        switch item.kind {
        case .train: drawTrain(&ctx, cam, item, t: t)
        case .barrier: drawBarrier(&ctx, cam, x: item.x, d: item.d0, t: t)
        case .coin: drawCoin(&ctx, cam, item, t: t)
        case .pop: drawPop(&ctx, cam, item)
        case .pole: drawPole(&ctx, cam, d: item.d0)
        case .runner: drawRunner(&ctx, cam, t: t, rx: runnerX)
        }
    }

    private func drawPole(_ ctx: inout GraphicsContext, _ cam: Cam, d: Double) {
        let p = cam.p(d), u = cam.lw * p
        let f = fog(d)
        let steel = col(mixc(hex(0x2A2034), Pal.haze, f))
        let rim = col(mixc(hex(0xF0A585), Pal.haze, f), 0.6)
        for side in [-1.0, 1.0] {
            let X = side * 2.2
            let x = cam.x(X, p)
            let yb = cam.y(0, p), yt = cam.y(2.75, p)
            let pw = max(0.8, 0.085 * u)
            ctx.fill(Path(CGRect(x: x - pw / 2, y: yt, width: pw, height: yb - yt)), with: .color(steel))
            ctx.fill(Path(CGRect(x: x - side * pw / 2 - (side > 0 ? 0 : 0), y: yt, width: max(0.5, pw * 0.22), height: yb - yt)),
                     with: .color(rim))
            let plinth = CGRect(x: x - pw * 1.3, y: cam.y(0.2, p), width: pw * 2.6, height: cam.y(0, p) - cam.y(0.2, p))
            ctx.fill(Path(plinth), with: .color(col(mixc(hex(0x5A4552), Pal.haze, f))))
            var arm = Path()
            arm.move(to: cam.pt(X, 2.45, p))
            arm.addLine(to: cam.pt(side * 1.12, 2.45, p))
            arm.move(to: cam.pt(X, 2.12, p))
            arm.addLine(to: cam.pt(side * 1.6, 2.45, p))
            arm.move(to: cam.pt(side * 1.25, 2.45, p))
            arm.addLine(to: cam.pt(side * 1.25, 2.2, p))
            ctx.stroke(arm, with: .color(steel), lineWidth: max(0.6, 0.04 * u))
        }
    }

    private func drawBarrier(_ ctx: inout GraphicsContext, _ cam: Cam, x X: Double, d: Double, t: Double) {
        let p = cam.p(d), u = cam.lw * p
        let f = fog(d)
        let fade = 1 - smoothstep(Self.farD * 0.8, Self.farD, d)
        // Shadow, legs, striped board, warning lamp.
        let pb = cam.p(d + 0.3)
        var shadow = Path()
        shadow.move(to: cam.pt(X - 0.5, 0, p))
        shadow.addLine(to: cam.pt(X + 0.5, 0, p))
        shadow.addLine(to: cam.pt(X + 0.5, 0, pb))
        shadow.addLine(to: cam.pt(X - 0.5, 0, pb))
        shadow.closeSubpath()
        ctx.fill(shadow, with: .color(col(Pal.ink, 0.35 * fade)))
        let legC = col(mixc(hex(0xD9D2DA), Pal.haze, f), fade)
        for lx in [-0.36, 0.36] {
            let r = CGRect(x: cam.x(X + lx - 0.03, p), y: cam.y(0.24, p), width: max(0.6, 0.06 * u), height: 0.24 * u)
            ctx.fill(Path(r), with: .color(legC))
            ctx.fill(Path(CGRect(x: cam.x(X + lx - 0.07, p), y: cam.y(0.04, p), width: 0.14 * u, height: 0.04 * u)),
                     with: .color(col(mixc(hex(0x3A3040), Pal.haze, f), fade)))
        }
        let board = CGRect(x: cam.x(X - 0.47, p), y: cam.y(0.42, p), width: 0.94 * u, height: 0.2 * u)
        var top = Path()
        top.move(to: cam.pt(X - 0.47, 0.42, p))
        top.addLine(to: cam.pt(X + 0.47, 0.42, p))
        top.addLine(to: cam.pt(X + 0.47, 0.42, cam.p(d + 0.07)))
        top.addLine(to: cam.pt(X - 0.47, 0.42, cam.p(d + 0.07)))
        top.closeSubpath()
        ctx.fill(top, with: .color(col(mixc(hex(0xFFE27A), Pal.haze, f), fade)))
        ctx.fill(Path(board), with: .color(col(mixc(hex(0xFFC61A), Pal.haze, f), fade)))
        if u > 6 {
            var stripes = Path()
            let sp = 0.2 * u, bh = board.height
            var sx = board.minX - bh
            while sx < board.maxX {
                stripes.move(to: CGPoint(x: sx, y: board.maxY))
                stripes.addLine(to: CGPoint(x: sx + sp * 0.5, y: board.maxY))
                stripes.addLine(to: CGPoint(x: sx + sp * 0.5 + bh, y: board.minY))
                stripes.addLine(to: CGPoint(x: sx + bh, y: board.minY))
                stripes.closeSubpath()
                sx += sp
            }
            var c = ctx
            c.clip(to: Path(board))
            c.fill(stripes, with: .color(col(mixc(hex(0x1B1720), Pal.haze, f), fade)))
        }
        ctx.stroke(Path(board), with: .color(col(Pal.ink, 0.5 * fade)), lineWidth: max(0.5, 0.012 * u))
        // Blinking amber lamp.
        let on = fract(t * 1.7 + X * 0.3) < 0.55
        let lr = max(0.8, 0.045 * u)
        let lp = cam.pt(X, 0.47, p)
        ctx.fill(Path(ellipseIn: CGRect(x: lp.x - lr, y: lp.y - lr, width: lr * 2, height: lr * 2)),
                 with: .color(col(on ? hex(0xFFB23A) : hex(0x8A5A2A), fade)))
        if on {
            var g = ctx
            g.blendMode = .plusLighter
            g.fill(Path(ellipseIn: CGRect(x: lp.x - lr * 4, y: lp.y - lr * 4, width: lr * 8, height: lr * 8)),
                   with: .radialGradient(Gradient(colors: [col(hex(0xFFA030), 0.55 * fade), col(hex(0xFFA030), 0)]),
                                         center: lp, startRadius: 0, endRadius: lr * 4))
        }
    }

    private func drawCoin(_ ctx: inout GraphicsContext, _ cam: Cam, _ item: Item, t: Double) {
        let p = cam.p(item.d0), u = cam.lw * p
        let r = 0.13 * u
        guard r > 0.5 else { return }
        let f = fog(item.d0)
        let fade = 1 - smoothstep(Self.farD * 0.75, Self.farD, item.d0)
        let x = cam.x(item.x, p), y = cam.y(item.y, p)
        let gy = cam.y(0, p)
        ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.8, y: gy - r * 0.22, width: r * 1.6, height: r * 0.44)),
                 with: .color(col(Pal.ink, 0.28 * fade)))
        if r > 2.5 {
            var g = ctx
            g.blendMode = .plusLighter
            g.fill(Path(ellipseIn: CGRect(x: x - r * 2.3, y: y - r * 2.3, width: r * 4.6, height: r * 4.6)),
                   with: .radialGradient(Gradient(colors: [col(hex(0xFFC23A), 0.32 * fade), col(hex(0xFFC23A), 0)]),
                                         center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 2.3))
        }
        let sx = 0.22 + 0.78 * abs(cos(t * 5.2 + item.aux * 2.3))
        let rimC = mixc(hex(0xC0800A), Pal.haze, f)
        ctx.fill(Path(ellipseIn: CGRect(x: x - r * sx, y: y - r, width: 2 * r * sx, height: 2 * r)), with: .color(col(rimC, fade)))
        let ir = r * 0.8
        ctx.fill(Path(ellipseIn: CGRect(x: x - ir * sx, y: y - ir, width: 2 * ir * sx, height: 2 * ir)),
                 with: .linearGradient(Gradient(colors: [col(mixc(hex(0xFFF1A6), Pal.haze, f), fade), col(mixc(hex(0xF2AE1C), Pal.haze, f), fade)]),
                                       startPoint: CGPoint(x: x, y: y - ir), endPoint: CGPoint(x: x, y: y + ir)))
        if r > 3 {
            let er = r * 0.5
            ctx.stroke(Path(ellipseIn: CGRect(x: x - er * sx, y: y - er, width: 2 * er * sx, height: 2 * er)),
                       with: .color(col(mixc(hex(0xD4920E), Pal.haze, f), fade)), lineWidth: max(0.5, r * 0.12))
            if sx > 0.55 {
                var gem = Path()
                let gr = r * 0.26
                gem.move(to: CGPoint(x: x, y: y - gr))
                gem.addLine(to: CGPoint(x: x + gr * 0.7 * sx, y: y))
                gem.addLine(to: CGPoint(x: x, y: y + gr))
                gem.addLine(to: CGPoint(x: x - gr * 0.7 * sx, y: y))
                gem.closeSubpath()
                ctx.fill(gem, with: .color(col(hex(0xFFF7D0), 0.9 * fade)))
            }
        }
    }

    /// A collected token: a token-sized sparkle that blooms and fades in a quarter second.
    private func drawPop(_ ctx: inout GraphicsContext, _ cam: Cam, _ item: Item) {
        let f = item.aux / 0.25
        let p = cam.p(Self.runnerD), u = cam.lw * p
        let x = cam.x(item.x + (item.code & 1 == 0 ? -0.07 : 0.07), p), y = cam.y(item.y + 0.2 + 0.14 * f, p)
        var g = ctx
        g.blendMode = .plusLighter
        let R = 0.11 * u * (0.7 + 0.6 * sin(.pi * min(1, f * 1.4)))
        g.fill(Path(ellipseIn: CGRect(x: x - R * 0.9, y: y - R * 0.9, width: R * 1.8, height: R * 1.8)),
               with: .radialGradient(Gradient(colors: [col(hex(0xFFD54A), 0.6 * (1 - f)), col(hex(0xFFD54A), 0)]),
                                     center: CGPoint(x: x, y: y), startRadius: 0, endRadius: R * 0.9))
        var star = Path()
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 + f * 0.6
            let rad = i % 2 == 0 ? R : R * 0.24
            let q = CGPoint(x: x + cos(a) * rad, y: y + sin(a) * rad)
            if i == 0 { star.move(to: q) } else { star.addLine(to: q) }
        }
        star.closeSubpath()
        g.fill(star, with: .color(col(hex(0xFFF3C0), 1 - f * f)))
    }
}

// MARK: Trains

extension RailRushRenderer {
    private func groundQuad(_ cam: Cam, _ x0: Double, _ x1: Double, _ pa: Double, _ pb: Double, Y: Double = 0) -> Path {
        var q = Path()
        q.move(to: cam.pt(x0, Y, pa))
        q.addLine(to: cam.pt(x1, Y, pa))
        q.addLine(to: cam.pt(x1, Y, pb))
        q.addLine(to: cam.pt(x0, Y, pb))
        q.closeSubpath()
        return q
    }

    /// Quad on the vertical plane X = xs between depths da...db and heights ya...yb.
    private func sideQuad(_ path: inout Path, _ cam: Cam, _ xs: Double, _ da: Double, _ db: Double, _ ya: Double, _ yb: Double) {
        let pa = cam.p(da), pb = cam.p(db)
        path.move(to: cam.pt(xs, ya, pa))
        path.addLine(to: cam.pt(xs, yb, pa))
        path.addLine(to: cam.pt(xs, yb, pb))
        path.addLine(to: cam.pt(xs, ya, pb))
        path.closeSubpath()
    }

    fileprivate func drawTrain(_ ctx: inout GraphicsContext, _ cam: Cam, _ item: Item, t: Double) {
        let X = item.x, front = item.aux
        let d0 = max(item.d0, Self.nearD), d1 = item.d1
        guard d1 > d0 + 0.01 else { return }
        let palette = item.code & 15, cars = (item.code >> 4) & 15, oncoming = item.code & 256 != 0
        let isFront = front >= Self.nearD && item.d0 <= front + 1e-6
        let bw = 0.41, y0 = 0.16, y1 = 1.04
        let p0 = cam.p(d0), p1 = cam.p(d1)
        let fade = 1 - smoothstep(Self.farD * 0.82, Self.farD, front)
        let body = Pal.trainBody[palette], stripe = Pal.trainStripe[palette]
        var c = ctx
        c.opacity = fade

        // Headlight wash on the ballast and rails ahead of an oncoming train.
        if isFront && oncoming && front > 0.6 {
            let pa = cam.p(front), pn = cam.p(max(Self.nearD, front - 4))
            var g = c
            g.blendMode = .plusLighter
            let k = 1 - fog(front)
            g.fill(groundQuad(cam, X - 0.52, X + 0.52, pa, pn), with: .linearGradient(
                Gradient(colors: [col(hex(0xFFD9A0), 0.34 * k), col(hex(0xFFB070), 0)]),
                startPoint: CGPoint(x: 0, y: cam.y(0, pa)), endPoint: CGPoint(x: 0, y: cam.y(0, pn))))
            var rails = Path()
            for side in [-0.245, 0.245] { rails.addPath(groundQuad(cam, X + side - 0.025, X + side + 0.025, pa, pn, Y: 0.06)) }
            g.fill(rails, with: .linearGradient(
                Gradient(colors: [col(hex(0xFFF4DA), 0.9 * k), col(hex(0xFFE0B0), 0)]),
                startPoint: CGPoint(x: 0, y: cam.y(0, pa)), endPoint: CGPoint(x: 0, y: cam.y(0, pn))))
        }

        // Contact shadow on the ballast.
        c.fill(groundQuad(cam, X - 0.5, X + 0.5, p0, p1), with: .color(col(Pal.ink, 0.4)))

        let detail = cam.lw * p0 > 5
        // Side face (only the one turned toward the camera is visible).
        if abs(X - cam.camX) > bw {
            let xs = X > cam.camX ? X - bw : X + bw
            let sideC = mixc(body * 0.66, hex(0x3B2944), 0.18)
            let gNear = CGPoint(x: cam.x(xs, p0), y: 0), gFar = CGPoint(x: cam.x(xs, p1), y: 0)
            var face = Path()
            sideQuad(&face, cam, xs, d0, d1, y0, y1)
            c.fill(face, with: .linearGradient(Gradient(colors: [col(mixc(sideC, Pal.haze, fog(d0))), col(mixc(sideC, Pal.haze, fog(d1)))]),
                                               startPoint: gNear, endPoint: gFar))
            var under = Path()
            sideQuad(&under, cam, xs + (X > cam.camX ? 0.05 : -0.05), d0, d1, 0.03, y0)
            c.fill(under, with: .color(col(mixc(hex(0x1C1620), Pal.haze, fog(d0) * 0.7))))
            var band = Path()
            sideQuad(&band, cam, xs, d0, d1, 0.37, 0.45)
            let stripeS = stripe * 0.78
            c.fill(band, with: .linearGradient(Gradient(colors: [col(mixc(stripeS, Pal.haze, fog(d0))), col(mixc(stripeS, Pal.haze, fog(d1)))]),
                                               startPoint: gNear, endPoint: gFar))
            if detail {
                var glass = Path(), doors = Path(), gaps = Path()
                @inline(__always) func add(_ path: inout Path, _ za: Double, _ zb: Double, _ ya: Double, _ yb: Double) {
                    let da = max(front + za, d0), db = min(front + zb, d1)
                    if db > da + 0.005 { sideQuad(&path, cam, xs, da, db, ya, yb) }
                }
                for car in 0..<cars {
                    let o = Double(car) * (RailPlan.carLength + RailPlan.carGap)
                    for (a, b) in [(0.55, 1.05), (3.65, 4.15)] {
                        add(&doors, o + a, o + b, 0.19, 0.92)
                        add(&glass, o + a + 0.08, o + b - 0.08, 0.56, 0.86)
                    }
                    for a in [1.35, 2.05, 2.75, 4.45] { add(&glass, o + a, o + a + 0.48, 0.55, 0.87) }
                    if car < cars - 1 { add(&gaps, o + RailPlan.carLength, o + RailPlan.carLength + RailPlan.carGap, 0.1, 1.0) }
                }
                let fm = fog((d0 + min(d1, d0 + 6)) / 2)
                c.fill(doors, with: .color(col(mixc(sideC * 0.82, Pal.haze, fm))))
                c.fill(glass, with: .color(col(mixc(hex(0x1C1830), Pal.haze, fm * 0.9))))
                c.fill(gaps, with: .color(col(mixc(hex(0x120E16), Pal.haze, fm * 0.8))))
            }
        }

        // Roof, seen from above.
        if cam.g - y1 * cam.lw > 0 {
            let roofC = mixc(body, hex(0xF2C3B5), 0.22) * 0.92
            let gNear = CGPoint(x: 0, y: cam.y(y1, p0)), gFar = CGPoint(x: 0, y: cam.y(y1, p1))
            c.fill(groundQuad(cam, X - bw, X + bw, p0, p1, Y: y1), with: .linearGradient(
                Gradient(colors: [col(mixc(roofC, Pal.haze, fog(d0))), col(mixc(roofC, Pal.haze, fog(d1)))]),
                startPoint: gNear, endPoint: gFar))
            if detail {
                var units = Path()
                for car in 0..<cars {
                    let o = Double(car) * (RailPlan.carLength + RailPlan.carGap)
                    let da = max(front + o + 1.4, d0), db = min(front + o + 3.4, d1)
                    if db > da { units.addPath(groundQuad(cam, X - 0.22, X + 0.22, cam.p(da), cam.p(db), Y: y1 + 0.06)) }
                    if car < cars - 1 {
                        let ga = max(front + o + RailPlan.carLength, d0), gb = min(front + o + RailPlan.carLength + RailPlan.carGap, d1)
                        if gb > ga { units.addPath(groundQuad(cam, X - bw, X + bw, cam.p(ga), cam.p(gb), Y: y1)) }
                    }
                }
                c.fill(units, with: .color(col(mixc(roofC * 0.72, Pal.haze, fog(d0 + 2)))))
            }
        }

        guard isFront else { return }
        drawTrainFront(&c, cam, X: X, d: front, body: body, stripe: stripe, lit: oncoming, t: t)
    }

    private func drawTrainFront(_ c: inout GraphicsContext, _ cam: Cam, X: Double, d: Double,
                                body: RGB, stripe: RGB, lit: Bool, t: Double) {
        let p = cam.p(d), u = cam.lw * p
        let f = fog(d)
        @inline(__always) func rect(_ xa: Double, _ xb: Double, _ ya: Double, _ yb: Double) -> CGRect {
            CGRect(x: cam.x(X + xa, p), y: cam.y(yb, p), width: (xb - xa) * u, height: (yb - ya) * u)
        }
        @inline(__always) func fc(_ rgb: RGB, _ a: Double = 1) -> Color { col(mixc(rgb, Pal.haze, f), a) }

        c.fill(Path(rect(-0.36, 0.36, 0.03, 0.17)), with: .color(fc(hex(0x1C1620))))
        let shell = rect(-0.41, 0.41, 0.16, 1.04)
        let shellPath = Path(roundedRect: shell, cornerRadii: RectangleCornerRadii(
            topLeading: 0.12 * u, bottomLeading: 0.02 * u, bottomTrailing: 0.02 * u, topTrailing: 0.12 * u))
        c.fill(shellPath, with: .linearGradient(
            Gradient(colors: [fc(mixc(body, hex(0xFFD9C0), 0.2)), fc(body * 0.84)]),
            startPoint: CGPoint(x: 0, y: shell.minY), endPoint: CGPoint(x: 0, y: shell.maxY)))
        guard u > 3 else { return }
        c.fill(Path(rect(-0.41, 0.41, 0.16, 0.22)), with: .color(fc(body * 0.6)))
        c.fill(Path(rect(-0.41, 0.41, 0.36, 0.45)), with: .color(fc(stripe)))
        let shield = rect(-0.31, 0.31, 0.56, 0.88)
        c.fill(Path(roundedRect: shield, cornerRadius: 0.05 * u), with: .linearGradient(
            Gradient(colors: [fc(hex(0x463A68)), fc(hex(0x14101F))]),
            startPoint: CGPoint(x: 0, y: shield.minY), endPoint: CGPoint(x: 0, y: shield.maxY)))
        var streak = Path()
        streak.move(to: CGPoint(x: shield.minX + shield.width * 0.18, y: shield.maxY))
        streak.addLine(to: CGPoint(x: shield.minX + shield.width * 0.34, y: shield.maxY))
        streak.addLine(to: CGPoint(x: shield.minX + shield.width * 0.52, y: shield.minY))
        streak.addLine(to: CGPoint(x: shield.minX + shield.width * 0.36, y: shield.minY))
        streak.closeSubpath()
        c.fill(streak, with: .color(col(hex(0xF2B8C8), 0.16 * (1 - f))))
        c.fill(Path(rect(-0.016, 0.016, 0.56, 0.88)), with: .color(fc(body * 0.9)))
        c.fill(Path(roundedRect: rect(-0.17, 0.17, 0.905, 0.975), cornerRadius: 0.015 * u),
               with: .color(lit ? fc(hex(0xFFB347)) : fc(hex(0x5A4A3E))))
        c.stroke(shellPath, with: .color(col(Pal.ink, 0.45 * (1 - f))), lineWidth: max(0.5, 0.012 * u))

        let lr = 0.05 * u
        for side in [-0.29, 0.29] {
            let lp = cam.pt(X + side, 0.28, p)
            let lamp = CGRect(x: lp.x - lr, y: lp.y - lr, width: lr * 2, height: lr * 2)
            c.fill(Path(ellipseIn: lamp.insetBy(dx: -lr * 0.3, dy: -lr * 0.3)), with: .color(fc(hex(0x241C28))))
            c.fill(Path(ellipseIn: lamp), with: .color(lit ? col(hex(0xFFF6DC)) : fc(hex(0x9A8E80))))
            if lit {
                var g = c
                g.blendMode = .plusLighter
                let flicker = 0.9 + 0.1 * sin(t * 23 + X * 5)
                g.fill(Path(ellipseIn: lamp.insetBy(dx: -lr * 4, dy: -lr * 4)), with: .radialGradient(
                    Gradient(colors: [col(hex(0xFFE7B0), 0.7 * flicker * (1 - f * 0.6)), col(hex(0xFFB070), 0)]),
                    center: lp, startRadius: lr * 0.5, endRadius: lr * 5))
            }
        }
        if !lit {
            for side in [-0.35, 0.35] {
                let mp = cam.pt(X + side, 0.95, p)
                let mr = max(0.5, 0.022 * u)
                c.fill(Path(ellipseIn: CGRect(x: mp.x - mr, y: mp.y - mr, width: mr * 2, height: mr * 2)),
                       with: .color(fc(hex(0xE0453A))))
            }
        }
    }
}

// MARK: Runner

extension RailRushRenderer {
    fileprivate func drawRunner(_ ctx: inout GraphicsContext, _ cam: Cam, t: Double, rx: (x: Double, vel: Double)) {
        let p = cam.p(Self.runnerD), u = cam.lw * p
        let lift = RailPlan.lift(t)
        let jump = RailPlan.jumpPhase(t)
        let x = cam.x(rx.x, p), ground = cam.y(0, p)
        let ln = lift / RailPlan.jumpHeight

        // Shadow stays on the ground and shrinks while airborne.
        let sw = 0.56 * u * (1 - 0.35 * ln), sh = 0.15 * u * (1 - 0.35 * ln)
        let shadow = CGRect(x: x - sw / 2, y: ground - sh / 2, width: sw, height: sh)
        ctx.fill(Path(ellipseIn: shadow), with: .radialGradient(
            Gradient(colors: [col(hex(0x0C070C), 0.75 * (1 - 0.4 * ln)), col(hex(0x0C070C), 0)]),
            center: CGPoint(x: shadow.midX, y: shadow.midY), startRadius: 0, endRadius: sw * 0.5))
        if let since = RailPlan.sinceLanding(t), since < 0.35 {
            let k = since / 0.35
            var puffs = Path()
            for i in -1...1 {
                let r = (0.05 + 0.07 * k) * u * (i == 0 ? 0.8 : 1)
                let px = x + Double(i) * (0.12 + 0.22 * k) * u
                puffs.addEllipse(in: CGRect(x: px - r, y: ground - r * 1.2 - 0.04 * u * k, width: r * 2, height: r * 1.5))
            }
            ctx.fill(puffs, with: .color(col(hex(0xE2B9B6), 0.5 * (1 - k))))
        }

        var c = ctx
        c.translateBy(x: x, y: ground - lift * u)
        c.scaleBy(x: u, y: u)
        c.rotate(by: .radians(clamp(rx.vel * 0.05, -0.2, 0.2)))
        let ink = col(Pal.ink, 0.7)
        let line = max(0.012, 0.9 / u)

        let ph = t * 2 * .pi * 2.3
        let sL = sin(ph)
        let air = jump != nil
        let bob = air ? 0.02 : 0.035 * abs(sL)
        let hipY = -0.42 - bob

        // Legs: the planted one first, then the one kicking back toward the camera.
        let legOrder: [Double] = sL > 0 ? [1, -1] : [-1, 1]
        for side in legOrder {
            let kick: Double
            if let j = jump { kick = 0.55 + 0.25 * sin(j * .pi) * (side < 0 ? 1 : 0.7) } else { kick = max(0, side < 0 ? sL : -sL) }
            let fx = side * (0.1 + 0.015 * kick), fy = -0.03 - 0.2 * kick
            var leg = Path()
            leg.move(to: CGPoint(x: side * 0.085, y: hipY))
            leg.addLine(to: CGPoint(x: fx, y: fy - 0.05))
            c.stroke(leg, with: .color(ink), style: StrokeStyle(lineWidth: 0.135 + line * 2, lineCap: .round))
            c.stroke(leg, with: .color(col(Pal.pants)), style: StrokeStyle(lineWidth: 0.135, lineCap: .round))
            // Sneaker seen from the heel; a lifted foot shows its sole.
            let shoeH = 0.085 + 0.035 * kick
            let shoe = CGRect(x: fx - 0.08, y: fy - shoeH + 0.02, width: 0.16, height: shoeH)
            let shoePath = Path(roundedRect: shoe, cornerRadius: 0.04)
            c.fill(shoePath, with: .color(col(Pal.sneaker)))
            let soleH = 0.025 + 0.045 * kick
            c.fill(Path(roundedRect: CGRect(x: shoe.minX, y: shoe.maxY - soleH, width: shoe.width, height: soleH), cornerRadius: 0.02),
                   with: .color(col(hex(0xC7BDB6))))
            c.fill(Path(roundedRect: CGRect(x: fx - 0.025, y: shoe.minY + 0.012, width: 0.05, height: 0.035), cornerRadius: 0.01),
                   with: .color(col(hex(0x2FA6A0))))
            c.stroke(shoePath, with: .color(ink), lineWidth: line)
        }

        let shoulderY = -0.77 - bob
        // Arms swinging forward are mostly hidden behind the torso, so they go first.
        func arm(_ side: Double, _ back: Double) {
            let elbow = CGPoint(x: side * 0.27, y: shoulderY + (air ? 0.02 : 0.13))
            let fwdHand = CGPoint(x: side * 0.16, y: shoulderY + 0.04)
            let backHand = CGPoint(x: side * 0.25, y: shoulderY + 0.31)
            let k = air ? 0.15 : (back + 1) / 2
            var hand = CGPoint(x: fwdHand.x + (backHand.x - fwdHand.x) * k, y: fwdHand.y + (backHand.y - fwdHand.y) * k)
            if air { hand = CGPoint(x: side * 0.33, y: shoulderY - 0.06) }
            var a = Path()
            a.move(to: CGPoint(x: side * 0.17, y: shoulderY + 0.02))
            a.addLine(to: elbow)
            a.addLine(to: hand)
            c.stroke(a, with: .color(ink), style: StrokeStyle(lineWidth: 0.11 + line * 2, lineCap: .round, lineJoin: .round))
            c.stroke(a, with: .color(col(Pal.hoodie)), style: StrokeStyle(lineWidth: 0.11, lineCap: .round, lineJoin: .round))
            c.fill(Path(ellipseIn: CGRect(x: hand.x - 0.05, y: hand.y - 0.05, width: 0.1, height: 0.1)), with: .color(col(Pal.hoodieDark)))
        }
        let backL = -sL, backR = sL
        if backL < 0 || air { arm(-1, backL) }
        if backR < 0 && !air { arm(1, backR) }

        // Hoodie body.
        let torso = CGRect(x: -0.2, y: shoulderY - 0.06, width: 0.4, height: -0.38 - (shoulderY - 0.06) + 0.0)
        let torsoPath = Path(roundedRect: torso, cornerRadii: RectangleCornerRadii(
            topLeading: 0.13, bottomLeading: 0.06, bottomTrailing: 0.06, topTrailing: 0.13))
        c.fill(torsoPath, with: .color(ink))
        c.fill(torsoPath, with: .linearGradient(Gradient(colors: [col(hex(0x2C9AA0)), col(Pal.hoodie), col(Pal.hoodieDark)]),
                                                startPoint: CGPoint(x: 0, y: torso.minY), endPoint: CGPoint(x: 0, y: torso.maxY)))
        c.fill(Path(roundedRect: CGRect(x: torso.minX + 0.01, y: torso.maxY - 0.05, width: torso.width - 0.02, height: 0.045),
                    cornerRadius: 0.02), with: .color(col(hex(0x124C52))))
        c.stroke(torsoPath, with: .color(ink), lineWidth: line)

        // Hood up, no face (we only ever see the back).
        let hood = CGRect(x: -0.15, y: shoulderY - 0.25, width: 0.3, height: 0.27)
        c.fill(Path(ellipseIn: hood), with: .radialGradient(
            Gradient(colors: [col(hex(0x2FA3A8)), col(Pal.hoodie), col(hex(0x13525A))]),
            center: CGPoint(x: hood.midX - 0.05, y: hood.minY + 0.06), startRadius: 0, endRadius: 0.24))
        c.stroke(Path(ellipseIn: hood), with: .color(ink), lineWidth: line)
        var seam = Path()
        seam.move(to: CGPoint(x: 0, y: hood.minY + 0.03))
        seam.addQuadCurve(to: CGPoint(x: 0, y: hood.maxY - 0.02), control: CGPoint(x: 0.012, y: hood.midY))
        c.stroke(seam, with: .color(col(hex(0x0E4046), 0.8)), lineWidth: 0.014)
        var rim = Path()
        rim.addArc(center: CGPoint(x: hood.midX, y: hood.midY), radius: 0.135, startAngle: .degrees(200), endAngle: .degrees(300), clockwise: false)
        c.stroke(rim, with: .color(col(hex(0xFFB48A), 0.75)), style: StrokeStyle(lineWidth: 0.018, lineCap: .round))

        // Bright yellow backpack, bouncing a beat behind the body.
        let lag = air ? -0.02 : 0.014 * sin(ph * 2 - 0.9)
        let pack = CGRect(x: -0.155, y: shoulderY + 0.015 + lag, width: 0.31, height: 0.33)
        var straps = Path()
        for side in [-1.0, 1.0] {
            straps.move(to: CGPoint(x: side * 0.1, y: pack.minY + 0.02))
            straps.addLine(to: CGPoint(x: side * 0.13, y: shoulderY - 0.045))
        }
        c.stroke(straps, with: .color(col(hex(0xD9A400))), style: StrokeStyle(lineWidth: 0.045, lineCap: .round))
        let packPath = Path(roundedRect: pack, cornerRadius: 0.075)
        c.fill(packPath, with: .linearGradient(Gradient(colors: [col(hex(0xFFDB3F)), col(Pal.backpack), col(hex(0xE9B200))]),
                                               startPoint: CGPoint(x: 0, y: pack.minY), endPoint: CGPoint(x: 0, y: pack.maxY)))
        let flap = CGRect(x: pack.minX + 0.012, y: pack.minY + 0.01, width: pack.width - 0.024, height: 0.13)
        c.fill(Path(roundedRect: flap, cornerRadii: RectangleCornerRadii(topLeading: 0.065, bottomLeading: 0.05, bottomTrailing: 0.05, topTrailing: 0.065)),
               with: .color(col(hex(0xE8B100))))
        c.fill(Path(roundedRect: CGRect(x: -0.06, y: flap.maxY - 0.03, width: 0.12, height: 0.02), cornerRadius: 0.01),
               with: .color(col(hex(0xFFF2B0))))
        let pocket = CGRect(x: -0.1, y: pack.maxY - 0.12, width: 0.2, height: 0.09)
        c.fill(Path(roundedRect: pocket, cornerRadius: 0.035), with: .color(col(hex(0xF2BE00))))
        c.stroke(Path(roundedRect: pocket, cornerRadius: 0.035), with: .color(col(hex(0xB98A00))), lineWidth: line * 0.8)
        var zip = Path()
        zip.move(to: CGPoint(x: pocket.minX + 0.03, y: pocket.minY + 0.022))
        zip.addLine(to: CGPoint(x: pocket.maxX - 0.03, y: pocket.minY + 0.022))
        c.stroke(zip, with: .color(col(hex(0x8A6600))), lineWidth: 0.012)
        c.stroke(packPath, with: .color(ink), lineWidth: line)

        if backL >= 0 && !air { arm(-1, backL) }
        if backR >= 0 || air { arm(1, air ? 0 : backR) }
    }

    // MARK: HUD

    fileprivate func drawHUD(_ ctx: inout GraphicsContext, w: Double, h: Double, t: Double) {
        guard min(w, h) >= 100 else { return }
        let fs = clamp(min(w, h) * 0.042, 10, 24)
        let pad = fs * 0.75, pillH = fs * 1.6, cy = pad + pillH / 2
        let font = Font.system(size: fs, weight: .heavy, design: .rounded).monospacedDigit()

        // Token count with a coin icon (pulses on each pickup).
        var pulse = 0.0
        for item in items where item.kind == .pop && item.aux < 0.18 { pulse = max(pulse, 1 - item.aux / 0.18) }
        let tokenText = ctx.resolve(Text(String(RailPlan.tokens(at: t))).font(font).foregroundStyle(Color.white))
        let tw = tokenText.measure(in: CGSize(width: w, height: h)).width
        let left = CGRect(x: pad, y: pad, width: pillH * 0.95 + tw + fs * 0.65, height: pillH)
        ctx.fill(Path(roundedRect: left, cornerRadius: pillH / 2), with: .color(col(Pal.ink, 0.5)))
        ctx.stroke(Path(roundedRect: left, cornerRadius: pillH / 2), with: .color(.white.opacity(0.12)), lineWidth: 1)
        let cr = fs * 0.46 * (1 + 0.18 * pulse)
        let cc = CGPoint(x: left.minX + pillH / 2, y: cy)
        ctx.fill(Path(ellipseIn: CGRect(x: cc.x - cr, y: cc.y - cr, width: cr * 2, height: cr * 2)), with: .color(col(hex(0xC0800A))))
        ctx.fill(Path(ellipseIn: CGRect(x: cc.x - cr * 0.78, y: cc.y - cr * 0.78, width: cr * 1.56, height: cr * 1.56)),
                 with: .linearGradient(Gradient(colors: [col(hex(0xFFF1A6)), col(hex(0xF2AE1C))]),
                                       startPoint: CGPoint(x: 0, y: cc.y - cr), endPoint: CGPoint(x: 0, y: cc.y + cr)))
        var gem = Path()
        gem.move(to: CGPoint(x: cc.x, y: cc.y - cr * 0.32))
        gem.addLine(to: CGPoint(x: cc.x + cr * 0.24, y: cc.y))
        gem.addLine(to: CGPoint(x: cc.x, y: cc.y + cr * 0.32))
        gem.addLine(to: CGPoint(x: cc.x - cr * 0.24, y: cc.y))
        gem.closeSubpath()
        ctx.fill(gem, with: .color(col(hex(0xFFF7D0))))
        ctx.draw(tokenText, at: CGPoint(x: left.minX + pillH * 0.95, y: cy), anchor: .leading)

        // Distance meter.
        let distText = ctx.resolve(Text("\(Int(RailPlan.speed * t)) m").font(font).foregroundStyle(Color.white))
        let dw = distText.measure(in: CGSize(width: w, height: h)).width
        let right = CGRect(x: w - pad - dw - fs * 1.3, y: pad, width: dw + fs * 1.3, height: pillH)
        ctx.fill(Path(roundedRect: right, cornerRadius: pillH / 2), with: .color(col(Pal.ink, 0.5)))
        ctx.stroke(Path(roundedRect: right, cornerRadius: pillH / 2), with: .color(.white.opacity(0.12)), lineWidth: 1)
        ctx.draw(distText, at: CGPoint(x: right.midX, y: cy), anchor: .center)
    }
}

// MARK: Yard buildings

extension RailRushRenderer {
    /// Low warehouses and sheds beyond the walls, painted far to near for parallax.
    fileprivate func drawYard(_ ctx: inout GraphicsContext, _ cam: Cam, s: Double) {
        let rD = Self.runnerD, slot = 6.0
        var outside = Path()
        for side in [-1.0, 1.0] {
            outside.addPath(strip(cam, side * 2.7, side * 14))
        }
        ctx.fill(outside, with: .linearGradient(Gradient(colors: [col(hex(0x7A5060), 0.5), col(hex(0x1E1420), 0.7)]),
                                                startPoint: CGPoint(x: 0, y: cam.hy), endPoint: CGPoint(x: 0, y: cam.hy + cam.g)))
        let first = ((s - rD + Self.nearD - 8) / slot).rounded(.down)
        var j = ((s - rD + Self.farD) / slot).rounded(.up)
        while j >= first {
            for side in [-1.0, 1.0] {
                let seed = Int(j) &* 2 &+ (side > 0 ? 1 : 0)
                @inline(__always) func r(_ k: Int) -> Double { hash01(seed &* 16 &+ 7000 &+ k) }
                if r(0) < 0.22 { continue }
                let d0 = j * slot + r(1) * 1.2 - s + rD
                let d1 = d0 + 2.6 + 2.6 * r(2)
                if d1 < Self.nearD + 0.1 || d0 > Self.farD { continue }
                let da = max(d0, Self.nearD), pa = cam.p(da), pb = cam.p(d1)
                let xin = side * (3.1 + 0.8 * r(3)), xout = xin + side * (1.6 + 2.2 * r(4))
                let H = 1.45 + 0.9 * r(5)
                let f = fog(da)
                let tint = r(6) < 0.5 ? hex(0x3E2A4E) : hex(0x4A2E44)
                var face = Path()
                face.move(to: cam.pt(xin, 0, pa))
                face.addLine(to: cam.pt(xin, H, pa))
                face.addLine(to: cam.pt(xin, H, pb))
                face.addLine(to: cam.pt(xin, 0, pb))
                face.closeSubpath()
                ctx.fill(face, with: .color(col(mixc(tint * 0.8, Pal.haze, f))))
                if cam.g - H * cam.lw > 0 {
                    var roof = Path()
                    roof.move(to: cam.pt(xin, H, pa))
                    roof.addLine(to: cam.pt(xout, H, pa))
                    roof.addLine(to: cam.pt(xout, H, pb))
                    roof.addLine(to: cam.pt(xin, H, pb))
                    roof.closeSubpath()
                    ctx.fill(roof, with: .color(col(mixc(mixc(tint, hex(0xC98A9A), 0.35), Pal.haze, f))))
                }
                guard d0 >= Self.nearD else { continue }
                let x0 = cam.x(min(xin, xout), pa), x1 = cam.x(max(xin, xout), pa)
                let front = CGRect(x: x0, y: cam.y(H, pa), width: x1 - x0, height: cam.y(0, pa) - cam.y(H, pa))
                ctx.fill(Path(front), with: .linearGradient(
                    Gradient(colors: [col(mixc(mixc(tint, hex(0xE79A86), 0.3), Pal.haze, f)), col(mixc(tint, Pal.haze, f))]),
                    startPoint: CGPoint(x: 0, y: front.minY), endPoint: CGPoint(x: 0, y: front.maxY)))
                if front.height > 10 {
                    // A grid of small windows, some lit.
                    var lit = Path()
                    let cols = max(2, Int(front.width / max(4, front.height * 0.16)))
                    let ww = front.width / Double(cols * 2 + 1), wh = front.height * 0.09
                    for row in 0..<2 {
                        for k in 0..<cols where hash01(seed &* 64 &+ row &* 17 &+ k &+ 7300) > 0.55 {
                            lit.addRect(CGRect(x: front.minX + ww * Double(2 * k + 1), y: front.minY + front.height * (0.22 + 0.22 * Double(row)),
                                               width: ww, height: wh))
                        }
                    }
                    ctx.fill(lit, with: .color(col(mixc(hex(0xFFC46B), Pal.haze, f * 0.6), 0.8)))
                }
            }
            j -= 1
        }
    }
}
