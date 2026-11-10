import AppKit

/// The frame behind a session (a brick wall, or plain black): fills the whole display and is stacked directly under
/// the locked-in window, so the app and the clip read as one split screen instead of two
/// windows floating on the desktop.
///
/// It never takes clicks or focus. Clicks fall through to whatever is behind it, and it
/// sits at the normal window level, so any other window you bring forward covers it.
final class FrameBackdrop: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        backgroundColor = NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1)
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        // .transient: Mission Control hides it instead of offering it as a window. Picking it
        // there would raise the wall over the app and the clip.
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
    }

    var style: FrameStyle = .black {
        didSet {
            guard style != oldValue else { return }
            if style == .bricks {
                contentView = BrickWallView(frame: contentRect(forFrameRect: frame))
            } else if contentView is BrickWallView {
                contentView = NSView()
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
