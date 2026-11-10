import CoreGraphics

public enum ScreenGeometry {
    /// Converts a rect between AppKit global coordinates (origin at the bottom-left
    /// of the primary display, y up — `NSScreen.frame`, `NSWindow.frame`) and
    /// Quartz / Accessibility global coordinates (origin at the top-left of the
    /// primary display, y down — `kAXPositionAttribute`, `CGWindowListCopyWindowInfo`).
    ///
    /// The conversion is its own inverse. `primaryScreenHeight` must be the height of
    /// the display that holds the menu bar origin (`NSScreen.screens[0].frame.height`),
    /// not of whichever screen the rect is on.
    public static func flipped(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a point the same way (for a point, not a rect origin).
    public static func flipped(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Two frames are "the same" for window-management purposes if every edge is
    /// within `tolerance` points (apps round sizes to their own grid).
    public static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
