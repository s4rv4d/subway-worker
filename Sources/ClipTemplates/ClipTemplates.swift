import SubwayWorkerCore
import SwiftUI

/// Draws a built-in procedural loop that fills whatever frame it's given (from a thin
/// 220pt strip to a 2000pt-tall panel, portrait or landscape) and animates forever.
public struct TemplateClipView: View {
    let template: ClipTemplate
    let isPaused: Bool

    public init(template: ClipTemplate, isPaused: Bool = false) {
        self.template = template
        self.isPaused = isPaused
    }

    public var body: some View {
        switch template {
        case .railRush: RailRushView(isPaused: isPaused)
        case .neonRunner: NeonRunnerView(isPaused: isPaused)
        case .ringBounce: RingBounceView(isPaused: isPaused)
        case .bouncingBadge: CornerHunterView(isPaused: isPaused)
        }
    }
}
