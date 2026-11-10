import AppKit
import Observation
import SubwayWorkerCore
import WindowTiling

/// Runs one "lock in" session: the chosen app's window on one side, the gameplay
/// panel on the other, kept in sync as screens change and either side is resized.
@Observable
final class SessionController {
    enum Phase: Equatable {
        case idle
        case starting(String)
        case active
        /// Putting the window back where it was after the session ended.
        case ending
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var target: AppChoice?
    /// The concrete side the clip is on right now.
    private(set) var resolvedPlacement: ResolvedPlacement = .right

    var isActive: Bool { phase == .active }
    var screenSize: CGSize? { screen?.visibleFrame.size }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let tiler = WindowTiler()
    @ObservationIgnored private var window: TargetWindow?
    @ObservationIgnored private var observer: TargetWindowObserver?
    /// Where the window was before we snapped it (nil if it was full screen).
    @ObservationIgnored private var originalFrame: CGRect?
    @ObservationIgnored private var wasFullScreen = false
    @ObservationIgnored private var lastAppliedAppFrame: CGRect?
    @ObservationIgnored private var displayID: CGDirectDisplayID?
    @ObservationIgnored private var panel: GameplayPanel?
    @ObservationIgnored private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// The black frame behind the split (see `FrameBackdrop`).
    @ObservationIgnored private var backdrop: FrameBackdrop?
    /// The locked-in window's window-server number, for stacking the frame right under it.
    @ObservationIgnored private var targetWindowNumber: CGWindowID?
    @ObservationIgnored private var restackTask: Task<Void, Never>?
    @ObservationIgnored private var backdropCheckTask: Task<Void, Never>?
    /// macOS refused to stack the frame under the window, so it's off for this session.
    @ObservationIgnored private var frameBlocked = false
    /// The locked-in app (or Subway Worker itself) is the frontmost app.
    @ObservationIgnored private var targetInFront = true
    /// The locked-in app is hidden (⌘H).
    @ObservationIgnored private var targetAppHidden = false
    /// The locked-in window is minimized to the Dock.
    @ObservationIgnored private var targetMinimized = false
    /// Bumped whenever a session starts or ends. Async work captures it and bails out if
    /// it changed while suspended, so a stale step can never act on a newer session.
    @ObservationIgnored private var generation = 0

    /// Space between the two sides, and around them, when the frame is on. Wider for the
    /// brick wall, so you actually see some bricks.
    static func frameGap(for style: FrameStyle) -> CGFloat {
        switch style {
        case .bricks: 14
        case .black: 8
        case .off: 0
        }
    }

    init(model: AppModel) {
        self.model = model
    }

    // MARK: Lifecycle

    func start(_ choice: AppChoice) async {
        guard AccessibilityAccess.isTrusted else {
            phase = .failed(TilingError.notTrusted.localizedDescription)
            return
        }
        // Same app again → just apply any new settings.
        if isActive, target?.id == choice.id, let window, tiler.isAlive(window) {
            relayout(focusApp: true)
            await layoutTask?.value
            return
        }
        if isActive || window != nil {
            await end(restore: model.restoreOnEnd)
        }
        await restoreTask?.value // let the previous window finish going back first

        generation += 1
        let generation = self.generation
        phase = .starting(choice.name)
        target = choice

        do {
            let window: TargetWindow
            if let running = choice.runningApplication {
                window = try await tiler.resolveWindow(for: running)
            } else if let url = choice.bundleURL {
                window = try await tiler.launchApp(at: url).1
            } else {
                throw TilingError.appNotRunning(choice.name)
            }
            guard generation == self.generation else { return } // superseded by a newer start/end

            self.window = window
            targetWindowNumber = tiler.windowNumber(of: window)
            wasFullScreen = tiler.isFullScreen(window)
            let frame = tiler.frame(of: window)
            originalFrame = wasFullScreen ? nil : frame
            displayID = (frame.flatMap(Self.screen(containing:)) ?? NSScreen.main)?.displayID

            try installObservers(for: window)
            showPanel()
            phase = .active
            relayout(focusApp: true)
            await layoutTask?.value
        } catch {
            guard generation == self.generation else { return }
            teardown()
            target = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops the session, optionally putting the app's window back the way it was.
    func end(restore: Bool) async {
        generation += 1
        let generation = self.generation
        let window = self.window
        let originalFrame = self.originalFrame
        let wasFullScreen = self.wasFullScreen
        teardown() // also cancels any in-flight layout
        target = nil

        guard restore, let window else {
            phase = .idle
            return
        }
        phase = .ending
        let tiler = self.tiler
        let task = Task {
            guard tiler.isAlive(window) else { return }
            if wasFullScreen {
                try? tiler.enterFullScreen(window)
            } else if let originalFrame {
                _ = try? await tiler.setFrame(originalFrame, of: window)
            }
        }
        restoreTask = task
        await task.value
        if generation == self.generation {
            restoreTask = nil
            phase = .idle
        }
    }

    /// Waits for a window restore that's still running (used when quitting).
    func waitForPendingRestore() async {
        await restoreTask?.value
    }

    /// Re-snaps both sides (after settings changed, or from the menu).
    /// With `moveWindow: false` only the panel is re-laid out.
    func relayout(focusApp: Bool = false, moveWindow: Bool = true) {
        guard isActive else { return }
        layoutTask?.cancel()
        let generation = self.generation
        layoutTask = Task {
            await applyLayout(focusApp: focusApp, moveWindow: moveWindow, generation: generation)
        }
    }

    /// Shows, hides and stacks the clip panel to match which app is in front and what the
    /// user picked for "When I switch apps".
    func updatePanelPresence() {
        guard isActive, let panel else { return }
        let behavior = model.switchAwayBehavior
        panel.level = behavior == .stayOnTop ? .floating : .normal

        // The app itself is out of sight, or you left it and the clip should go too.
        if targetAppHidden || targetMinimized || (behavior == .hide && !targetInFront) {
            panel.orderOut(nil)
            model.playback.isSuspended = true
            return
        }
        model.playback.isSuspended = false
        if targetInFront || behavior == .stayOnTop {
            panel.orderFrontRegardless()
        } else if !panel.isVisible {
            // Another app is in front: reappear underneath its windows, not over them.
            panel.orderBack(nil)
        }
        // Otherwise leave it where it is: the other app's windows already cover it.
        stackBackdrop()
    }

    /// Keeps the black frame directly under the locked-in window: it covers the desktop and
    /// every other window, but never the window itself (or the clip, which sits above).
    private func stackBackdrop() {
        guard let backdrop else { return }
        guard isFrameOn, targetWindowNumber != nil, let screen,
              !targetAppHidden, !targetMinimized,
              model.switchAwayBehavior != .hide || targetInFront
        else {
            backdrop.orderOut(nil)
            return
        }
        backdrop.style = model.frameStyle
        if backdrop.frame != screen.frame {
            backdrop.setFrame(screen.frame, display: false)
            backdrop.contentView?.needsDisplay = true // the wall is drawn once per size
        }
        // With another app in front its windows already cover the frame, so leave it put,
        // unless it isn't on screen yet; then tuck it under the window wherever that is.
        if targetInFront || !backdrop.isVisible {
            restack()
            checkBackdropSoon()
        }
    }

    /// Puts the wall directly under the locked-in window and the clip back above the wall.
    /// Always both moves together: "directly under the app" lands the wall on top of the
    /// clip whenever the app's window has been raised above the clip in the meantime.
    private func restack() {
        guard let backdrop, let number = targetWindowNumber else { return }
        backdrop.order(.below, relativeTo: Int(number))
        guard let panel, panel.isVisible else { return }
        if targetInFront {
            panel.orderFrontRegardless()
        } else if panel.level == backdrop.level {
            // Another app is in front: stay under its windows, just above the wall.
            panel.order(.above, relativeTo: backdrop.windowNumber)
        }
    }

    /// Safety net: whatever reordered our windows, the wall must never sit on top of the
    /// clip. Runs when the clip stops being visible; only looks at our own two windows.
    private func clipOcclusionChanged() {
        guard isActive, let panel, let backdrop, panel.isVisible, backdrop.isVisible,
              !panel.occlusionState.contains(.visible),
              let order = NSWindow.windowNumbers(options: [])?.map(\.intValue),
              let wallIndex = order.firstIndex(of: backdrop.windowNumber),
              let clipIndex = order.firstIndex(of: panel.windowNumber),
              wallIndex < clipIndex // front to back: the wall is in front of the clip
        else { return }
        restack()
    }

    /// Safety net: the frame must never cover the window. If macOS didn't let us stack it
    /// underneath (e.g. a permission was denied), take it away for the rest of the session.
    private func checkBackdropSoon() {
        backdropCheckTask?.cancel()
        let generation = self.generation
        backdropCheckTask = Task {
            // Two strikes: one bad reading can just be windows still settling after a switch.
            for attempt in 1...2 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, generation == self.generation, isActive, targetInFront, !frameBlocked,
                      let backdrop, backdrop.isVisible, let number = targetWindowNumber
                else { return }
                if Self.isWindow(CGWindowID(backdrop.windowNumber), below: number) { return }
                if attempt == 1 { restack() }
            }
            frameBlocked = true
            backdrop?.orderOut(nil)
            relayout(moveWindow: model.keepSnapped) // drops the gap
        }
    }

    /// Whether `window` is anywhere below `reference` in the on-screen stacking order.
    /// Uses window numbers only (front to back): no owners, names or positions of anyone's windows.
    private static func isWindow(_ window: CGWindowID, below reference: CGWindowID) -> Bool {
        guard let order = NSWindow.windowNumbers(options: [.allApplications])?.map({ CGWindowID($0.intValue) }),
              let referenceIndex = order.firstIndex(of: reference),
              let windowIndex = order.firstIndex(of: window)
        else { return true } // can't tell; don't tear anything down
        return windowIndex > referenceIndex
    }

    /// The app we just switched to may raise its window a beat after telling us it's active.
    /// Stack the frame again once it has, so it doesn't end up under the window's old spot.
    private func restackSoon() {
        restackTask?.cancel()
        let generation = self.generation
        restackTask = Task {
            for delay in [100, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, generation == self.generation, targetInFront else { return }
                stackBackdrop()
            }
        }
    }

    /// A frame style is picked, and the app exposed its window number so we can stack under it.
    private var isFrameOn: Bool { model.frameStyle != .off && targetWindowNumber != nil && !frameBlocked }

    /// The gap between (and around) the two sides.
    private var gap: CGFloat { isFrameOn ? Self.frameGap(for: model.frameStyle) : 0 }

    /// Where the split goes on a screen: its visible frame, inset by the gap.
    private func layoutArea(of screen: NSScreen) -> CGRect {
        screen.visibleFrame.insetBy(dx: gap, dy: gap)
    }

    // MARK: Layout

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            // Mostly off-screen: pick the screen it overlaps most.
            ?? NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
    }

    private func currentLayout() -> SplitLayout? {
        guard let screen else { return nil }
        return SplitLayout.compute(in: layoutArea(of: screen), placement: model.placement, sizing: model.sizing, gap: gap)
    }

    private func applyLayout(focusApp: Bool, moveWindow: Bool, generation: Int) async {
        guard isActive, generation == self.generation, let window, let layout = currentLayout() else { return }
        resolvedPlacement = layout.placement
        panel?.setFrame(layout.clipFrame, display: true)
        updatePanelPresence()
        // A minimized window stays in the Dock; it's re-snapped when it comes back.
        guard moveWindow, !targetMinimized else { return }

        lastAppliedAppFrame = layout.appFrame
        do {
            // setFrame also tells the window's observers to expect the frame it lands on.
            let actual = try await tiler.setFrame(layout.appFrame, of: window)
            guard isActive, generation == self.generation, !Task.isCancelled else { return }
            lastAppliedAppFrame = actual
            if focusApp { tiler.focus(window) }
        } catch is CancellationError {
            // Superseded by a newer layout pass or the session ending.
        } catch {
            guard generation == self.generation, !tiler.isAlive(window) else { return }
            await end(restore: false)
        }
    }

    // MARK: Reacting to the user

    /// The user moved or resized the focused app's window.
    private func targetWindowChanged(to frame: CGRect) {
        guard isActive, !targetMinimized, let window, let screen else { return }

        // Gone full screen on purpose — leave it alone (re-snapping would kick it out).
        if tiler.isFullScreen(window) { return }

        // Dragged to another display → the session follows it there.
        if let newScreen = Self.screen(containing: frame), newScreen.displayID != displayID {
            displayID = newScreen.displayID
            relayout(moveWindow: model.keepSnapped)
            return
        }
        guard model.keepSnapped else { return }

        // A real drag that moved the window's inner edge moves the divider. Plain moves,
        // outer-edge drags and app-initiated size tweaks just snap back.
        if let last = lastAppliedAppFrame,
           abs(frame.width - last.width) > 4 || abs(frame.height - last.height) > 4,
           userJustReleasedMouse,
           let current = currentLayout() {
            let visible = layoutArea(of: screen)
            let implied = SplitLayout.clipExtent(impliedByAppFrame: frame, in: visible, placement: resolvedPlacement, gap: gap)
            // Zoomed/maximized to the screen edge → ignore rather than collapsing the clip.
            if implied >= SplitLayout.Limits.standard.minClipExtent * 0.5 {
                let resized = SplitLayout.layout(in: visible, placement: resolvedPlacement, clipExtent: implied, gap: gap)
                if abs(resized.clipExtent - current.clipExtent) > 4 {
                    model.sizing = .fraction(resized.clipShare(in: visible))
                }
            }
        }
        relayout()
    }

    /// The user dragged the gameplay panel's edge.
    fileprivate func panelResized(to frame: CGRect) {
        guard isActive, let screen, let current = currentLayout() else { return }
        let visible = layoutArea(of: screen)
        let extent = resolvedPlacement.isSideBySide ? frame.width : frame.height
        let resized = SplitLayout.layout(in: visible, placement: resolvedPlacement, clipExtent: extent, gap: gap)
        // Only a change along the split axis moves the divider (and switches sizing to Custom).
        if abs(resized.clipExtent - current.clipExtent) > 4 {
            model.sizing = .fraction(resized.clipShare(in: visible))
        }
        relayout()
    }

    /// Whether a mouse button came up in the last two seconds, i.e. the user just finished
    /// dragging something. Asks the system for the time since the last mouse-up; nothing is
    /// monitored or recorded, and no permission is involved.
    private var userJustReleasedMouse: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp) < 2
    }

    private func frontmostAppChanged(to pid: pid_t?) {
        guard isActive, let window else { return }
        let inFront = pid == window.pid || pid == ProcessInfo.processInfo.processIdentifier
        // Coming to the app or to Subway Worker always restacks, even when "in front" didn't
        // change: Mission Control, the Dock or ⌘-Tab can raise our windows out of order
        // (e.g. the wall over the app, or the app over the clip's side of the wall).
        guard inFront || targetInFront else { return }
        targetInFront = inFront
        updatePanelPresence()
        if inFront { restackSoon() }
    }

    private func targetAppVisibilityChanged(hidden: Bool) {
        guard isActive, hidden != targetAppHidden else { return }
        targetAppHidden = hidden
        updatePanelPresence()
    }

    private func targetMinimizedChanged(_ minimized: Bool) {
        guard isActive, minimized != targetMinimized else { return }
        targetMinimized = minimized
        if minimized {
            updatePanelPresence()
        } else {
            relayout() // also brings the clip back
        }
    }

    private func screensChanged() {
        guard isActive else { return }
        if !NSScreen.screens.contains(where: { $0.displayID == displayID }) {
            let windowFrame = window.flatMap { tiler.frame(of: $0) }
            displayID = (windowFrame.flatMap(Self.screen(containing:)) ?? NSScreen.main)?.displayID
        }
        relayout()
    }

    // MARK: Plumbing

    private func showPanel() {
        if panel == nil {
            let panel = GameplayPanel(model: model)
            panel.onUserResize = { [weak self] frame in self?.panelResized(to: frame) }
            self.panel = panel
            let center = NotificationCenter.default
            let token = center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipOcclusionChanged() }
            }
            notificationTokens.append((center, token))
        }
        if backdrop == nil { backdrop = FrameBackdrop() }
    }

    private func installObservers(for window: TargetWindow) throws {
        observer = try TargetWindowObserver(
            window: window,
            onUserChange: { [weak self] frame in self?.targetWindowChanged(to: frame) },
            onClose: { [weak self] in
                guard let self else { return }
                Task { await self.end(restore: false) }
            },
            onMinimizedChange: { [weak self] minimized in self?.targetMinimizedChanged(minimized) }
        )

        // Which app is in front decides whether the clip shows (see updatePanelPresence).
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetInFront = frontPID == window.pid || frontPID == ownPID
        targetAppHidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
        targetMinimized = false

        let workspace = NSWorkspace.shared.notificationCenter
        let targetPID = window.pid
        let activated = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let activePID = Self.pid(of: note)
            MainActor.assumeIsolated { self?.frontmostAppChanged(to: activePID) }
        }
        let hidden = workspace.addObserver(
            forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard Self.pid(of: note) == targetPID else { return }
            MainActor.assumeIsolated { self?.targetAppVisibilityChanged(hidden: true) }
        }
        let unhidden = workspace.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard Self.pid(of: note) == targetPID else { return }
            MainActor.assumeIsolated { self?.targetAppVisibilityChanged(hidden: false) }
        }
        notificationTokens += [(workspace, activated), (workspace, hidden), (workspace, unhidden)]

        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        notificationTokens.append((center, token))
    }

    private nonisolated static func pid(of note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    private func teardown() {
        layoutTask?.cancel()
        layoutTask = nil
        observer?.invalidate()
        observer = nil
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        targetInFront = true
        targetAppHidden = false
        targetMinimized = false
        model.playback.isSuspended = false
        restackTask?.cancel()
        restackTask = nil
        backdropCheckTask?.cancel()
        backdropCheckTask = nil
        targetWindowNumber = nil
        frameBlocked = false
        backdrop?.orderOut(nil)
        backdrop?.close()
        backdrop = nil
        if let panel {
            panel.orderOut(nil)
            // Drop the SwiftUI tree now so players and the web view stop immediately,
            // rather than whenever the panel happens to deallocate.
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        window = nil
        originalFrame = nil
        wasFullScreen = false
        lastAppliedAppFrame = nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
