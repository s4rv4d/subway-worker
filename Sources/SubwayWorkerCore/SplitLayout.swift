import CoreGraphics

/// Where the gameplay clip sits relative to the app you're focusing on.
public enum ClipPlacement: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Right on landscape screens, bottom on portrait screens (the TikTok split).
    case automatic
    case right
    case left
    case bottom
    case top

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .right: "Right"
        case .left: "Left"
        case .bottom: "Bottom"
        case .top: "Top"
        }
    }

    public func resolved(for screenSize: CGSize) -> ResolvedPlacement {
        switch self {
        case .automatic: screenSize.width >= screenSize.height ? .right : .bottom
        case .right: .right
        case .left: .left
        case .bottom: .bottom
        case .top: .top
        }
    }
}

/// A concrete side, after `.automatic` has been decided for a given screen.
public enum ResolvedPlacement: String, Codable, Sendable, CaseIterable {
    case right, left, bottom, top

    /// `true` when app and clip sit next to each other (split along the x axis).
    public var isSideBySide: Bool { self == .left || self == .right }

    /// The placement on the opposite side of the same axis.
    public var flipped: ResolvedPlacement {
        switch self {
        case .right: .left
        case .left: .right
        case .bottom: .top
        case .top: .bottom
        }
    }
}

/// How big the clip panel should be.
public enum ClipSizing: Codable, Equatable, Sendable {
    /// Size the panel like a phone held upright (9:16 at full screen height),
    /// clamped so it never eats too much or too little of the screen.
    case automatic
    /// A fixed share of the screen along the split axis (0...1).
    case fraction(Double)
}

/// Splits one screen's visible frame into an app area and a clip area.
///
/// All rects are in AppKit global coordinates (origin at the bottom-left of the
/// primary display, y grows upward), i.e. the same space as `NSScreen.visibleFrame`.
public struct SplitLayout: Equatable, Sendable {
    public var appFrame: CGRect
    public var clipFrame: CGRect
    public var placement: ResolvedPlacement

    public struct Limits: Equatable, Sendable {
        /// The clip never gets thinner than this (points).
        public var minClipExtent: CGFloat
        /// The app always keeps at least this much room (points).
        public var minAppExtent: CGFloat
        /// Bounds for `.automatic` sizing, as a share of the split axis.
        public var autoShare: ClosedRange<CGFloat>
        /// Bounds for `.fraction` sizing and user drags, as a share of the split axis.
        public var manualShare: ClosedRange<CGFloat>

        public init(
            minClipExtent: CGFloat = 220,
            minAppExtent: CGFloat = 480,
            autoShare: ClosedRange<CGFloat> = 0.15...0.42,
            manualShare: ClosedRange<CGFloat> = 0.12...0.6
        ) {
            self.minClipExtent = minClipExtent
            self.minAppExtent = minAppExtent
            self.autoShare = autoShare
            self.manualShare = manualShare
        }

        public static let standard = Limits()
    }

    /// Width / height of the classic vertical phone-gameplay crop.
    public static let phoneAspect: CGFloat = 9.0 / 16.0

    public init(appFrame: CGRect, clipFrame: CGRect, placement: ResolvedPlacement) {
        self.appFrame = appFrame
        self.clipFrame = clipFrame
        self.placement = placement
    }

    /// Thickness of the clip along the split axis.
    public var clipExtent: CGFloat {
        placement.isSideBySide ? clipFrame.width : clipFrame.height
    }

    /// Computes the layout for a screen.
    ///
    /// `.automatic` sizing aims for a 9:16 panel at full height when side by side
    /// (≈35% of a MacBook screen, ≈23% of a 21:9 ultrawide, ≈16% of a 32:9 monster),
    /// and a 16:9 strip at full width when stacked on a portrait screen.
    ///
    /// `gap` leaves an empty strip (in points) between the app and the clip; it
    /// defaults to 0 (the two touch). A negative gap is treated as 0.
    public static func compute(
        in visibleFrame: CGRect,
        placement: ClipPlacement,
        sizing: ClipSizing,
        limits: Limits = .standard,
        gap: CGFloat = 0
    ) -> SplitLayout {
        let resolved = placement.resolved(for: visibleFrame.size)
        let axisLength = resolved.isSideBySide ? visibleFrame.width : visibleFrame.height

        let extent: CGFloat
        switch sizing {
        case .automatic:
            let ideal = resolved.isSideBySide
                ? visibleFrame.height * phoneAspect   // 9:16 panel, full height
                : visibleFrame.width * phoneAspect    // 16:9 strip, full width
            extent = ideal.clamped(to: axisLength * limits.autoShare.lowerBound...axisLength * limits.autoShare.upperBound)
        case .fraction(let share):
            let share = CGFloat(share).clamped(to: limits.manualShare)
            extent = axisLength * share
        }
        return layout(in: visibleFrame, placement: resolved, clipExtent: extent, limits: limits, gap: gap)
    }

    /// Lays out with an explicit clip thickness (e.g. after the user dragged a divider).
    /// The extent is clamped so both sides keep their minimum sizes.
    ///
    /// The clip sits flush against its outer edge and the app against the opposite
    /// edge, leaving exactly `gap` points of empty space between them
    /// (app extent + gap + clip extent == the full axis length). A negative gap is
    /// treated as 0.
    public static func layout(
        in visibleFrame: CGRect,
        placement: ResolvedPlacement,
        clipExtent: CGFloat,
        limits: Limits = .standard,
        gap: CGFloat = 0
    ) -> SplitLayout {
        let v = visibleFrame
        let gap = max(gap, 0)
        let axisLength = placement.isSideBySide ? v.width : v.height

        var clip = clipExtent
        let maxClip = min(axisLength - gap - limits.minAppExtent, axisLength * limits.manualShare.upperBound)
        let minClip = max(limits.minClipExtent, axisLength * limits.manualShare.lowerBound)
        if maxClip >= minClip {
            clip = clip.clamped(to: minClip...maxClip)
        } else {
            // Tiny screen: both minimums can't be honoured, fall back to a fixed share.
            clip = axisLength * 0.35
        }
        clip = clip.rounded()
        let app = axisLength - clip - gap

        let appFrame: CGRect
        let clipFrame: CGRect
        switch placement {
        case .right:
            appFrame = CGRect(x: v.minX, y: v.minY, width: app, height: v.height)
            clipFrame = CGRect(x: v.maxX - clip, y: v.minY, width: clip, height: v.height)
        case .left:
            clipFrame = CGRect(x: v.minX, y: v.minY, width: clip, height: v.height)
            appFrame = CGRect(x: v.minX + clip + gap, y: v.minY, width: app, height: v.height)
        case .bottom:
            // AppKit y grows upward, so "bottom" is minY.
            clipFrame = CGRect(x: v.minX, y: v.minY, width: v.width, height: clip)
            appFrame = CGRect(x: v.minX, y: v.minY + clip + gap, width: v.width, height: app)
        case .top:
            appFrame = CGRect(x: v.minX, y: v.minY, width: v.width, height: app)
            clipFrame = CGRect(x: v.minX, y: v.maxY - clip, width: v.width, height: clip)
        }
        return SplitLayout(appFrame: appFrame, clipFrame: clipFrame, placement: placement)
    }

    /// The clip thickness implied by where the app window's inner edge now sits.
    /// Used when the user drags the focused app's window edge: whatever space is
    /// left on the clip's side becomes the clip, minus the `gap` kept between them.
    public static func clipExtent(
        impliedByAppFrame appFrame: CGRect,
        in visibleFrame: CGRect,
        placement: ResolvedPlacement,
        gap: CGFloat = 0
    ) -> CGFloat {
        let gap = max(gap, 0)
        return switch placement {
        case .right: visibleFrame.maxX - appFrame.maxX - gap
        case .left: appFrame.minX - visibleFrame.minX - gap
        case .bottom: appFrame.minY - visibleFrame.minY - gap
        case .top: visibleFrame.maxY - appFrame.maxY - gap
        }
    }

    /// The share of the split axis the clip occupies (handy for persisting user drags).
    public func clipShare(in visibleFrame: CGRect) -> Double {
        let axisLength = placement.isSideBySide ? visibleFrame.width : visibleFrame.height
        guard axisLength > 0 else { return 0 }
        return Double(clipExtent / axisLength)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
