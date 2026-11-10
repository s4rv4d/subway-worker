// Renders Resources/AppIcon.icns: a split screen — "work" on the left, a signal-yellow runner block on the right.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Squircle-ish base with the standard macOS icon margin.
    let base = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let basePath = NSBezierPath(roundedRect: base, xRadius: 185 * s, yRadius: 185 * s)
    func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    NSGradient(colors: [hex(0x19191B), hex(0x0E0E0F)])!.draw(in: basePath, angle: -90)
    basePath.addClip()

    // Left: the "work" window (mid gray) with a few faint text lines.
    let work = NSRect(x: 160 * s, y: 232 * s, width: 349 * s, height: 560 * s)
    hex(0x2A2A2D).setFill()
    NSBezierPath(roundedRect: work, xRadius: 40 * s, yRadius: 40 * s).fill()
    let widths: [CGFloat] = [250, 170, 220, 120]
    for (i, width) in widths.enumerated() {
        hex(0xEEECE7, 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: 200 * s, y: (704 - CGFloat(i) * 64) * s, width: width * s, height: 30 * s),
                     xRadius: 15 * s, yRadius: 15 * s).fill()
    }

    // Right: phone-shaped (9:16) signal-yellow block with a bold chevron.
    let lane = NSRect(x: 549 * s, y: 232 * s, width: 315 * s, height: 560 * s)
    hex(0xFCCC0A).setFill()
    NSBezierPath(roundedRect: lane, xRadius: 40 * s, yRadius: 40 * s).fill()
    let chevron = NSBezierPath()
    chevron.move(to: CGPoint(x: lane.midX - 90 * s, y: 468 * s))
    chevron.line(to: CGPoint(x: lane.midX, y: 558 * s))
    chevron.line(to: CGPoint(x: lane.midX + 90 * s, y: 468 * s))
    chevron.lineWidth = 64 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    hex(0x111112).setStroke()
    chevron.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: pixels).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
