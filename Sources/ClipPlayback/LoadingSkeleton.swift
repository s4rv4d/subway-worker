import SwiftUI

/// What a clip looks like before it plays: placeholder shapes with a soft highlight
/// sweeping across them, instead of a spinner on a black screen.
///
/// Drawn in one `Canvas` pass, so it's cheap. The sweep stops when `isAnimated` is false
/// (the clip is paused or out of sight) and for people who turn on Reduce Motion.
struct LoadingSkeleton: View {
    var isAnimated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let base = Color(red: 0.071, green: 0.071, blue: 0.075)
    private static let block = Color(red: 0.150, green: 0.150, blue: 0.163)
    /// One sweep plus a short rest, in seconds.
    private static let cycle = 1.7
    private static let sweepShare = 0.72

    var body: some View {
        let moves = isAnimated && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !moves)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                Self.draw(&context, size: size, sweep: moves ? Self.sweepPosition(at: timeline.date) : nil)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading clip")
    }

    /// 0...1 across one sweep, eased, then held at 1 for the rest of the cycle.
    static func sweepPosition(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        let t = min(phase / sweepShare, 1)
        return t * t * (3 - 2 * t)
    }

    static func draw(_ context: inout GraphicsContext, size: CGSize, sweep: Double?) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .color(base))

        // A diagonal band of light that travels from off the left edge to off the right.
        func highlight(_ opacity: Double) -> GraphicsContext.Shading? {
            guard let sweep else { return nil }
            let band = max(size.width * 0.9, 160)
            let center = -band + (size.width + 2 * band) * sweep
            return .linearGradient(
                Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(opacity), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: center - band / 2, y: 0),
                endPoint: CGPoint(x: center + band / 2, y: band * 0.35)
            )
        }

        if let wash = highlight(0.05) { context.fill(Path(bounds), with: wash) }

        let shapes = placeholders(in: size)
        guard !shapes.isEmpty else { return }
        context.fill(shapes, with: .color(block))
        if let shine = highlight(0.14) { context.fill(shapes, with: shine) }
    }

    /// Stand-ins for what a clip usually shows: two small pills up top; at the bottom a
    /// progress bar, a round badge and two lines of text; and on tall panels a column of
    /// round buttons. Pieces are left out as the panel gets too small for them.
    static func placeholders(in size: CGSize) -> Path {
        var path = Path()
        let unit = min(size.width, size.height)
        guard unit >= 120 else { return path }

        let pad = max(unit * 0.06, 12)
        let line = min(max(unit * 0.035, 8), 14)
        let pill = line * 2.2

        // Top: two pills.
        let leftPill = CGRect(x: pad, y: pad, width: min(max(size.width * 0.24, 56), 140), height: pill)
        let rightWidth = min(max(size.width * 0.18, 44), 110)
        let rightPill = CGRect(x: size.width - pad - rightWidth, y: pad, width: rightWidth, height: pill)
        path.addRoundedRect(in: leftPill, cornerSize: CGSize(width: pill / 2, height: pill / 2))
        if rightPill.minX > leftPill.maxX + pad {
            path.addRoundedRect(in: rightPill, cornerSize: CGSize(width: pill / 2, height: pill / 2))
        }

        // Bottom: a thin progress bar, with the badge and text lines sitting on it.
        let bar = max(line * 0.3, 3)
        let barRect = CGRect(x: pad, y: size.height - pad - bar, width: size.width - pad * 2, height: bar)
        let badge = line * 3
        let rowBottom = barRect.minY - line * 1.2
        guard rowBottom - badge > leftPill.maxY + pad else { return path }
        path.addRoundedRect(in: barRect, cornerSize: CGSize(width: bar / 2, height: bar / 2))
        path.addEllipse(in: CGRect(x: pad, y: rowBottom - badge, width: badge, height: badge))

        let textX = pad + badge + line
        let textWidth = size.width - textX - pad
        if textWidth > 40 {
            let gap = line * 0.6
            let top = rowBottom - badge + (badge - (line * 2 + gap)) / 2
            let corner = CGSize(width: line / 2, height: line / 2)
            path.addRoundedRect(in: CGRect(x: textX, y: top, width: textWidth * 0.62, height: line), cornerSize: corner)
            path.addRoundedRect(in: CGRect(x: textX, y: top + line + gap, width: textWidth * 0.38, height: line), cornerSize: corner)
        }

        // Tall panels: a column of round buttons up the right-hand side.
        if size.height > size.width * 1.3, unit >= 200 {
            let button = line * 2.8
            let spacing = line * 1.3
            var y = rowBottom - badge - line * 2 - button
            for _ in 0..<3 where y > leftPill.maxY + pad * 2 {
                path.addEllipse(in: CGRect(x: size.width - pad - button, y: y, width: button, height: button))
                y -= button + spacing
            }
        }
        return path
    }
}
