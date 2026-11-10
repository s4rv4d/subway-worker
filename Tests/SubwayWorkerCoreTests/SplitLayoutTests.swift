import CoreGraphics
import Testing
@testable import SubwayWorkerCore

struct SplitLayoutTests {
    // A MacBook Pro 14" "looks like 1512×982" with a 33pt menu bar.
    let macbook = CGRect(x: 0, y: 0, width: 1512, height: 949)
    // 27" 1440p, 21:9 ultrawide, 32:9 super-ultrawide, and a portrait 1440p.
    let qhd = CGRect(x: 0, y: 0, width: 2560, height: 1415)
    let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1415)
    let superUltrawide = CGRect(x: 0, y: 0, width: 5120, height: 1415)
    let portrait = CGRect(x: 0, y: 0, width: 1440, height: 2535)

    @Test func automaticOnLaptopIsPhoneShaped() {
        let layout = SplitLayout.compute(in: macbook, placement: .automatic, sizing: .automatic)
        #expect(layout.placement == .right)
        let expectedWidth: CGFloat = 534 // 949 × 9/16 = 533.8, rounded
        #expect(layout.clipFrame.width == expectedWidth)
        #expect(layout.clipFrame.height == 949)
        #expect(layout.appFrame.width + layout.clipFrame.width == macbook.width)
        #expect(layout.appFrame.maxX == layout.clipFrame.minX)
    }

    @Test func automaticScalesDownOnWideScreens() {
        let shares = [qhd, ultrawide, superUltrawide].map {
            SplitLayout.compute(in: $0, placement: .automatic, sizing: .automatic).clipShare(in: $0)
        }
        // Wider screen → the clip takes a smaller share, but never below the floor.
        #expect(shares[0] > shares[1])
        #expect(shares[1] > shares[2])
        #expect(shares[2] >= 0.15 - 0.001)
    }

    @Test func automaticGoesBottomOnPortraitScreens() {
        let layout = SplitLayout.compute(in: portrait, placement: .automatic, sizing: .automatic)
        #expect(layout.placement == .bottom)
        #expect(layout.clipFrame.minY == portrait.minY)
        #expect(layout.clipFrame.width == portrait.width)
        #expect(layout.appFrame.minY == layout.clipFrame.maxY)
        #expect(layout.appFrame.maxY == portrait.maxY)
    }

    @Test(arguments: [ResolvedPlacement.right, .left, .bottom, .top])
    func framesTileTheScreenExactly(placement: ResolvedPlacement) {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1055) // secondary display left of primary
        let layout = SplitLayout.layout(in: screen, placement: placement, clipExtent: 400)
        #expect(layout.clipExtent == 400)
        #expect(!layout.appFrame.intersects(layout.clipFrame))
        #expect(layout.appFrame.union(layout.clipFrame) == screen)
    }

    @Test func leftAndTopPutTheClipOnTheRightSide() {
        let left = SplitLayout.layout(in: macbook, placement: .left, clipExtent: 500)
        #expect(left.clipFrame.minX == macbook.minX)
        #expect(left.appFrame.maxX == macbook.maxX)

        let top = SplitLayout.layout(in: macbook, placement: .top, clipExtent: 300)
        #expect(top.clipFrame.maxY == macbook.maxY) // AppKit: top = maxY
        #expect(top.appFrame.minY == macbook.minY)
    }

    @Test func extentIsClampedSoTheAppKeepsRoom() {
        let huge = SplitLayout.layout(in: macbook, placement: .right, clipExtent: 5000)
        #expect(huge.appFrame.width >= SplitLayout.Limits.standard.minAppExtent)
        let tiny = SplitLayout.layout(in: macbook, placement: .right, clipExtent: 10)
        #expect(tiny.clipFrame.width >= SplitLayout.Limits.standard.minClipExtent)
    }

    @Test func fractionSizingUsesTheShare() {
        let layout = SplitLayout.compute(in: qhd, placement: .right, sizing: .fraction(0.25))
        #expect(layout.clipFrame.width == 640)
    }

    @Test func impliedExtentFollowsTheAppsInnerEdge() {
        let layout = SplitLayout.layout(in: macbook, placement: .right, clipExtent: 500)
        var dragged = layout.appFrame
        dragged.size.width -= 120 // user dragged the app's right edge leftwards
        let extent = SplitLayout.clipExtent(impliedByAppFrame: dragged, in: macbook, placement: .right)
        #expect(extent == 620)

        let bottom = SplitLayout.layout(in: portrait, placement: .bottom, clipExtent: 800)
        var raised = bottom.appFrame
        raised.origin.y += 100
        raised.size.height -= 100
        #expect(SplitLayout.clipExtent(impliedByAppFrame: raised, in: portrait, placement: .bottom) == 900)
    }

    @Test func tinyScreenFallsBackToFixedShare() {
        let tiny = CGRect(x: 0, y: 0, width: 600, height: 400)
        let layout = SplitLayout.layout(in: tiny, placement: .right, clipExtent: 300)
        #expect(layout.clipFrame.width == 210)
        #expect(layout.appFrame.width == 390)
    }

    // MARK: Gap

    private func axisLength(_ rect: CGRect, _ placement: ResolvedPlacement) -> CGFloat {
        placement.isSideBySide ? rect.width : rect.height
    }

    private func extent(_ rect: CGRect, _ placement: ResolvedPlacement) -> CGFloat {
        placement.isSideBySide ? rect.width : rect.height
    }

    @Test(arguments: ResolvedPlacement.allCases)
    func gapSeparatesAppAndClipExactly(placement: ResolvedPlacement) {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let gap: CGFloat = 8
        let layout = SplitLayout.layout(in: screen, placement: placement, clipExtent: 400, gap: gap)
        let app = layout.appFrame
        let clip = layout.clipFrame

        #expect(!app.intersects(clip))
        #expect(extent(app, placement) + gap + extent(clip, placement) == axisLength(screen, placement))

        let distance: CGFloat
        switch placement {
        case .right: distance = clip.minX - app.maxX
        case .left: distance = app.minX - clip.maxX
        case .bottom: distance = app.minY - clip.maxY
        case .top: distance = clip.minY - app.maxY
        }
        #expect(distance == gap)

        // Outer edges stay flush with the screen; the other axis spans the full frame.
        if placement.isSideBySide {
            #expect(app.minY == screen.minY && app.height == screen.height)
            #expect(clip.minY == screen.minY && clip.height == screen.height)
        } else {
            #expect(app.minX == screen.minX && app.width == screen.width)
            #expect(clip.minX == screen.minX && clip.width == screen.width)
        }
        switch placement {
        case .right: #expect(app.minX == screen.minX && clip.maxX == screen.maxX)
        case .left: #expect(clip.minX == screen.minX && app.maxX == screen.maxX)
        case .bottom: #expect(clip.minY == screen.minY && app.maxY == screen.maxY)
        case .top: #expect(app.minY == screen.minY && clip.maxY == screen.maxY)
        }
    }

    @Test(arguments: ResolvedPlacement.allCases)
    func clipExtentRoundTripsThroughTheGap(placement: ResolvedPlacement) {
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1055)
        let gap: CGFloat = 8
        let layout = SplitLayout.layout(in: screen, placement: placement, clipExtent: 400, gap: gap)
        let implied = SplitLayout.clipExtent(
            impliedByAppFrame: layout.appFrame, in: screen, placement: placement, gap: gap
        )
        #expect(implied == layout.clipExtent)
    }

    @Test(arguments: ResolvedPlacement.allCases)
    func zeroGapMatchesOmittingIt(placement: ResolvedPlacement) {
        let withZero = SplitLayout.layout(in: macbook, placement: placement, clipExtent: 400, gap: 0)
        let omitted = SplitLayout.layout(in: macbook, placement: placement, clipExtent: 400)
        #expect(withZero == omitted)

        let computedZero = SplitLayout.compute(in: macbook, placement: .automatic, sizing: .automatic, gap: 0)
        let computedOmitted = SplitLayout.compute(in: macbook, placement: .automatic, sizing: .automatic)
        #expect(computedZero == computedOmitted)
    }

    @Test func negativeGapIsTreatedAsZero() {
        let negative = SplitLayout.layout(in: macbook, placement: .right, clipExtent: 400, gap: -20)
        #expect(negative == SplitLayout.layout(in: macbook, placement: .right, clipExtent: 400))
    }

    @Test func computeForwardsTheGap() {
        let layout = SplitLayout.compute(in: macbook, placement: .right, sizing: .automatic, gap: 8)
        #expect(layout.clipFrame.minX - layout.appFrame.maxX == 8)
    }

    @Test(arguments: ResolvedPlacement.allCases)
    func largeGapStillLeavesTheAppItsMinimum(placement: ResolvedPlacement) {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 1512)
        let minApp = SplitLayout.Limits.standard.minAppExtent
        let layout = SplitLayout.layout(in: screen, placement: placement, clipExtent: 5000, gap: 200)
        #expect(extent(layout.appFrame, placement) >= minApp)
        #expect(extent(layout.appFrame, placement) + 200 + layout.clipExtent == 1512)
        #expect(!layout.appFrame.intersects(layout.clipFrame))
    }
}

struct ScreenGeometryTests {
    @Test func flipIsItsOwnInverse() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let flipped = ScreenGeometry.flipped(rect, primaryScreenHeight: 982)
        #expect(flipped == CGRect(x: 100, y: 332, width: 800, height: 600))
        #expect(ScreenGeometry.flipped(flipped, primaryScreenHeight: 982) == rect)
    }

    @Test func secondaryDisplayAbovePrimary() {
        // A display stacked above the primary has AppKit y > primary height → negative AX y.
        let rect = CGRect(x: 0, y: 1100, width: 1000, height: 500)
        #expect(ScreenGeometry.flipped(rect, primaryScreenHeight: 1080).minY == -520)
    }

    @Test func approximateEquality() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(ScreenGeometry.approximatelyEqual(a, a.insetBy(dx: 1, dy: 1)))
        #expect(!ScreenGeometry.approximatelyEqual(a, a.offsetBy(dx: 10, dy: 0)))
    }
}
