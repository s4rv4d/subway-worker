import SwiftUI

// Shared helpers for the procedural loops. Everything here is tiny and allocation-free per frame.

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

@inline(__always)
func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

@inline(__always)
func fract(_ x: Double) -> Double { x - x.rounded(.down) }

/// Cheap stable hash -> 0...1, used for deterministic "random" scenery.
@inline(__always)
func hash01(_ n: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: n) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 29
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 32
    return Double(x & 0xFFFFFF) / Double(0x1000000)
}

enum Neon {
    static func color(_ hue: Double, s: Double = 0.85, b: Double = 1, a: Double = 1) -> Color {
        var h = hue.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return Color(hue: h, saturation: s, brightness: b, opacity: a)
    }
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(unit() * Double(hi - lo + 1)) % (hi - lo + 1) }
    mutating func sign() -> Double { unit() < 0.5 ? -1 : 1 }
}

/// Converts timeline dates into clamped frame deltas so a long pause or hitch never explodes the physics.
final class LoopClock {
    private var last: TimeInterval?
    func delta(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        defer { last = t }
        guard let last else { return 0 }
        return clamp(t - last, 0, 1.0 / 20.0)
    }
}

struct Spark {
    var x = 0.0, y = 0.0, z = 0.0
    var vx = 0.0, vy = 0.0, vz = 0.0
    var life = 0.0, maxLife = 1.0
    var hue = 0.0, size = 1.0
    var rot = 0.0, vrot = 0.0
}

/// Fixed-capacity particle ring buffer: no per-frame allocation.
struct SparkPool {
    var items: [Spark]
    private var next = 0
    init(capacity: Int) { items = Array(repeating: Spark(), count: capacity) }

    mutating func emit(_ s: Spark) {
        items[next] = s
        next = (next + 1) % items.count
    }

    mutating func step(_ dt: Double, gravity: Double = 0, drag: Double = 0) {
        let damp = max(0, 1 - drag * dt)
        for i in items.indices where items[i].life > 0 {
            items[i].life -= dt
            items[i].vy += gravity * dt
            items[i].vx *= damp
            items[i].vy *= damp
            items[i].x += items[i].vx * dt
            items[i].y += items[i].vy * dt
            items[i].z += items[i].vz * dt
            items[i].rot += items[i].vrot * dt
        }
    }
}

func drawText(
    _ ctx: inout GraphicsContext, _ s: String, size: Double, color: Color, at p: CGPoint,
    anchor: UnitPoint = .center, weight: Font.Weight = .heavy, design: Font.Design = .rounded,
    tracking: Double = 0
) {
    var t = Text(s).font(.system(size: size, weight: weight, design: design)).monospacedDigit()
    if tracking != 0 { t = t.tracking(tracking) }
    ctx.draw(ctx.resolve(t.foregroundStyle(color)), at: p, anchor: anchor)
}

/// Wraps a TimelineView + Canvas pair. When paused the timeline stops ticking, so the last frame stays put.
struct LoopHost: View {
    let isPaused: Bool
    let draw: (Date, inout GraphicsContext, CGSize) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(timeline.date, &context, size)
            }
        }
        .background(Color.black)
        .clipped()
        .accessibilityHidden(true)
    }
}
