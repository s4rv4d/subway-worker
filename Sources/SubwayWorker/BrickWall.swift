import AppKit

/// Static, procedurally drawn dark brick wall (running bond) with a vignette.
/// Used as the full-screen backdrop behind the snapped app window and clip panel.
final class BrickWallView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Clamp: AppKit may hand us an effectively infinite rect.
        let dirtyRect = dirtyRect.intersection(bounds)
        guard !dirtyRect.isNull, !dirtyRect.isEmpty else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Mortar base.
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.090, 0.071, 0.059, 1])!)
        ctx.fill(dirtyRect)

        drawBricks(ctx, dirtyRect: dirtyRect, space: space)
        drawShading(ctx, dirtyRect: dirtyRect, space: space)
    }

    // MARK: - Bricks

    private func drawBricks(_ ctx: CGContext, dirtyRect: NSRect, space: CGColorSpace) {
        let pitchW = Metrics.brickWidth
        let pitchH = Metrics.brickHeight
        let half = Metrics.joint / 2

        let rowMin = max(0, Int(floor(dirtyRect.minY / pitchH)) - 1)
        let rowMax = Int(ceil(dirtyRect.maxY / pitchH)) + 1
        guard rowMin <= rowMax else { return }

        for row in rowMin...rowMax {
            let offset: CGFloat = row % 2 == 0 ? 0 : -pitchW / 2
            let colMin = Int(floor((dirtyRect.minX - offset) / pitchW)) - 1
            let colMax = Int(ceil((dirtyRect.maxX - offset) / pitchW)) + 1
            let y = CGFloat(row) * pitchH
            for col in colMin...colMax {
                let x = CGFloat(col) * pitchW + offset
                let rect = CGRect(x: x + half, y: y + half,
                                  width: pitchW - Metrics.joint, height: pitchH - Metrics.joint)
                guard rect.intersects(dirtyRect) else { continue }
                drawBrick(ctx, rect: rect, row: row, col: col, space: space)
            }
        }
    }

    private func drawBrick(_ ctx: CGContext, rect: CGRect, row: Int, col: Int, space: CGColorSpace) {
        let h1 = hash(row, col, 1)
        let h2 = hash(row, col, 2)
        let h3 = hash(row, col, 3)
        let h4 = hash(row, col, 4)
        let h5 = hash(row, col, 5)

        var hue = 8 + 10 * unit(h1)                 // 8...18 degrees
        var sat = 0.45 + 0.20 * unit(h2)
        var bri = 0.26 + 0.14 * unit(h3)
        if h4 % 12 == 0 {                           // soot
            bri *= 0.62
            sat *= 0.85
        } else if h5 % 20 == 0 {                    // faded / orange
            hue += 8
            sat *= 0.82
            bri = min(0.42, bri * 1.05)
        }

        let base = rgb(hue: hue / 360, sat: sat, bri: bri)
        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: Metrics.corner,
                          cornerHeight: Metrics.corner, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(colorSpace: space, components: [base.0, base.1, base.2, 1])!)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.clip()

        // Top highlight (1pt) and bottom shade (2pt).
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.06])!)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 0.25])!)
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))

        // A few faint speckles.
        let count = 3 + Int(hash(row, col, 6) % 3)
        for i in 0..<count {
            let s = hash(row, col, 10 + i)
            let px = rect.minX + 2 + CGFloat(s & 0xFF) / 255 * (rect.width - 4)
            let py = rect.minY + 2 + CGFloat((s >> 8) & 0xFF) / 255 * (rect.height - 6)
            let size = 1 + CGFloat((s >> 16) & 1)
            let light = (s >> 17) & 1 == 0
            let a: CGFloat = 0.05 + 0.05 * CGFloat((s >> 18) & 3) / 3
            let c = light ? CGColor(colorSpace: space, components: [1, 0.85, 0.75, a])!
                          : CGColor(colorSpace: space, components: [0, 0, 0, a * 2])!
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: px, y: py, width: size, height: size))
        }
        ctx.restoreGState()
    }

    // MARK: - Vignette

    private func drawShading(_ ctx: CGContext, dirtyRect: NSRect, space: CGColorSpace) {
        ctx.saveGState()
        ctx.clip(to: dirtyRect)

        // Gentle top-to-bottom darkening (y grows downward in a flipped view).
        if let g = CGGradient(colorSpace: space,
                              colorComponents: [0, 0, 0, 0.0, 0, 0, 0, 0.22],
                              locations: [0, 1], count: 2) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.minY),
                                   end: CGPoint(x: 0, y: bounds.maxY), options: [])
        }

        // Radial vignette: clear centre, 55% black at the corners.
        if let g = CGGradient(colorSpace: space,
                              colorComponents: [0, 0, 0, 0.0, 0, 0, 0, 0.0, 0, 0, 0, 0.55],
                              locations: [0, 0.35, 1], count: 3) {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = hypot(bounds.width, bounds.height) / 2
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius,
                                   options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    // MARK: - Helpers

    private enum Metrics {
        static let brickWidth: CGFloat = 66
        static let brickHeight: CGFloat = 22
        static let joint: CGFloat = 3
        static let corner: CGFloat = 1.5
    }

    private func hash(_ row: Int, _ col: Int, _ salt: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: row) &* 0x9E3779B1
        h ^= UInt32(truncatingIfNeeded: col) &* 0x85EBCA77
        h ^= UInt32(truncatingIfNeeded: salt) &* 0xC2B2AE3D
        h ^= h >> 15
        h = h &* 0x2C1B3C6D
        h ^= h >> 12
        h = h &* 0x297A2D39
        h ^= h >> 15
        return h
    }

    private func unit(_ h: UInt32) -> CGFloat { CGFloat(h & 0xFFFF) / 65535 }

    private func rgb(hue: CGFloat, sat: CGFloat, bri: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let h = hue * 6
        let i = Int(floor(h)) % 6
        let f = h - floor(h)
        let p = bri * (1 - sat), q = bri * (1 - sat * f), t = bri * (1 - sat * (1 - f))
        switch i {
        case 0: return (bri, t, p)
        case 1: return (q, bri, p)
        case 2: return (p, bri, t)
        case 3: return (p, q, bri)
        case 4: return (t, p, bri)
        default: return (bri, p, q)
        }
    }
}
