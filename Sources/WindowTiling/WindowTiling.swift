import AppKit
import ApplicationServices
import SubwayWorkerCore

// The public API below is what the app target compiles against. All frames crossing this
// API are in AppKit global coordinates (origin bottom-left of the primary display, y up),
// like NSWindow.frame. Everything runs on the main actor; Accessibility calls are
// synchronous IPC bounded by a 1 s messaging timeout per request.

/// Accessibility permission helpers. Moving other apps' windows requires the user to
/// enable this app under System Settings ▸ Privacy & Security ▸ Accessibility.
public enum AccessibilityAccess {
    /// Whether this process is currently trusted. Cheap; safe to poll ~1×/s.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "would like to control this computer" prompt (macOS only shows
    /// it while the app is not yet listed). Returns the current trust state.
    @discardableResult
    public static func requestAccess() -> Bool {
        // The literal value of `kAXTrustedCheckOptionPrompt` (that global is a mutable
        // C variable, which strict concurrency rejects).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings at Privacy & Security ▸ Accessibility.
    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

public enum TilingError: LocalizedError, Equatable {
    case notTrusted
    case appNotRunning(String)
    case launchFailed(String)
    case noWindow(String)
    case axFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notTrusted: "Subway Worker needs Accessibility access to move other apps' windows."
        case .appNotRunning(let name): "\(name) isn't running."
        case .launchFailed(let name): "Couldn't launch \(name)."
        case .noWindow(let name): "\(name) has no window to snap. Open one and try again."
        case .axFailure(let detail): "Window control failed: \(detail)"
        }
    }
}

/// Handle to one window of another app.
public struct TargetWindow {
    public let pid: pid_t
    public let appName: String
    let element: AXUIElement

    init(pid: pid_t, appName: String, element: AXUIElement) {
        self.pid = pid
        self.appName = appName
        self.element = element
    }
}

public final class WindowTiler {
    public init() {}

    /// How often to look for a window while waiting for one to appear.
    static let pollInterval: Duration = .milliseconds(150)

    /// Windows smaller than this are helpers/popovers, not something to snap.
    static let minimumSnappableSize = CGSize(width: 160, height: 100)

    /// Height of the primary display (the one holding the menu bar origin), which anchors
    /// the AppKit ↔ Accessibility coordinate flip.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }

    // MARK: Finding windows

    /// Activates `app`, and returns its main window: focused window, else main window,
    /// else the first standard window. Unminimizes it if needed. Polls until `timeout`
    /// when the app has no window yet (e.g. it was just launched).
    public func resolveWindow(for app: NSRunningApplication, timeout: Duration = .seconds(6)) async throws -> TargetWindow {
        try await resolveWindow(for: app, timeout: timeout, reopenAfter: timeout / 2)
    }

    /// - Parameter reopenAfter: When to nudge a window-less app with a reopen event
    ///   (what a Dock click sends; most apps respond by opening a window).
    func resolveWindow(for app: NSRunningApplication, timeout: Duration, reopenAfter: Duration) async throws -> TargetWindow {
        guard AccessibilityAccess.isTrusted else { throw TilingError.notTrusted }
        let name = Self.displayName(of: app)
        let pid = app.processIdentifier
        guard !app.isTerminated, pid > 0 else { throw TilingError.appNotRunning(name) }

        let appElement = AX.application(pid)
        Self.activate(app, appElement: appElement)

        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + timeout
        var reopened = false

        while true {
            guard !app.isTerminated else { throw TilingError.appNotRunning(name) }

            let pick = Self.pickWindow(of: appElement)
            if pick.notTrusted { throw TilingError.notTrusted }
            if let element = pick.window {
                if AX.bool(element, AXName.minimized) == true, AX.setBool(element, AXName.minimized, false) == .success {
                    // Let the un-minimize animation finish so a following setFrame sticks.
                    try await waitUntilSettled(element, timeout: .seconds(1)) {
                        AX.bool(element, AXName.minimized) != true
                    }
                }
                if !pick.isFocused {
                    AX.perform(element, AXName.raiseAction)
                }
                return TargetWindow(pid: pid, appName: name, element: element)
            }

            let now = clock.now
            guard now < deadline else { throw TilingError.noWindow(name) }
            if !reopened, now - start >= reopenAfter {
                reopened = true
                Self.reopen(app)
            }
            try await Task.sleep(for: min(Self.pollInterval, deadline - now))
        }
    }

    /// Launches (or reuses, if already running) the app bundle at `appURL`, waits for it
    /// to finish launching, then resolves its window.
    public func launchApp(at appURL: URL, timeout: Duration = .seconds(12)) async throws -> (NSRunningApplication, TargetWindow) {
        guard AccessibilityAccess.isTrusted else { throw TilingError.notTrusted }
        let name = Self.displayName(ofBundleAt: appURL)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        let app: NSRunningApplication
        let wasRunning: Bool
        if let running = Self.runningInstance(of: appURL) {
            app = running
            wasRunning = true
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            } catch {
                throw TilingError.launchFailed(name)
            }
            wasRunning = false
        }

        while !app.isFinishedLaunching {
            guard !app.isTerminated, clock.now < deadline else { throw TilingError.launchFailed(name) }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !app.isTerminated else { throw TilingError.launchFailed(name) }

        // A fresh launch may still be restoring its windows, so only nudge it halfway in;
        // an instance that was already running and has no window won't grow one by itself.
        let remaining = max(deadline - clock.now, .seconds(2))
        let reopenAfter = wasRunning ? .milliseconds(500) : remaining / 2
        let window = try await resolveWindow(for: app, timeout: remaining, reopenAfter: reopenAfter)
        return (app, window)
    }

    // MARK: Geometry

    /// The window's current frame, or nil if it can't be read (e.g. it closed).
    public func frame(of window: TargetWindow) -> CGRect? {
        AX.frame(window.element).frame.map {
            ScreenGeometry.flipped($0, primaryScreenHeight: Self.primaryScreenHeight)
        }
    }

    /// Moves and resizes the window to `frame`.
    /// - Exits native full screen first and waits for the animation to finish.
    /// - Unminimizes the window.
    /// - Temporarily turns off the app's `AXEnhancedUserInterface` while resizing (it
    ///   makes some apps animate or ignore programmatic resizes), then restores it.
    /// - Applies size → position → size, so a window near a screen edge isn't clamped.
    /// Returns the frame the window actually ended up with (apps may enforce min sizes).
    ///
    /// Live `TargetWindowObserver`s of this window ignore the moves this causes, and get
    /// their `expectedFrame` set to the returned frame.
    @discardableResult
    public func setFrame(_ frame: CGRect, of window: TargetWindow) async throws -> CGRect {
        guard AccessibilityAccess.isTrusted else { throw TilingError.notTrusted }
        let element = window.element
        FrameChangeRegistry.beginProgrammaticChange(element)
        defer { FrameChangeRegistry.endProgrammaticChange(element) }

        // One cheap read first: a closed window or a hung app fails here in ≤1 s instead of
        // stalling the main thread through every step below.
        let (startFrame, probeError) = AX.frame(element)
        switch probeError {
        case .invalidUIElement, .cannotComplete, .apiDisabled:
            throw Self.failure(probeError, "move the window", window)
        default:
            break
        }

        if AX.bool(element, AXName.fullScreen) == true {
            let error = AX.setBool(element, AXName.fullScreen, false)
            guard error == .success else { throw Self.failure(error, "exit full screen", window) }
            // AXFullScreen can flip before the window starts animating; also wait for the
            // frame to leave the full-screen rect, or the exit animation would undo our frame.
            try await waitUntilSettled(element, timeout: .seconds(2), leaving: startFrame) {
                AX.bool(element, AXName.fullScreen) != true
            }
        }

        if AX.bool(element, AXName.minimized) == true {
            let error = AX.setBool(element, AXName.minimized, false)
            guard error == .success else { throw Self.failure(error, "unminimize the window", window) }
            try await waitUntilSettled(element, timeout: .seconds(1)) {
                AX.bool(element, AXName.minimized) != true
            }
        }

        try applyFrame(frame, to: window)
        let actual = try await settledFrame(of: window, target: frame)
        FrameChangeRegistry.didApply(actual, to: element)
        return actual
    }

    // MARK: Lifecycle

    /// Whether the window still exists.
    public func isAlive(_ window: TargetWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return false }
        // A busy app (.cannotComplete) or revoked trust says nothing about the window; only
        // .invalidUIElement means it is gone.
        return AX.copy(window.element, AXName.role).error != .invalidUIElement
    }

    /// The window-server number of the window (the `CGWindowID` that `NSWindow.order(_:relativeTo:)`
    /// and `CGWindowListCopyWindowInfo` use), so our own windows can be stacked right next to it.
    /// Nil if the app doesn't expose one.
    public func windowNumber(of window: TargetWindow) -> CGWindowID? {
        var number: CGWindowID = 0
        guard _AXUIElementGetWindow(window.element, &number) == .success, number != 0 else { return nil }
        return number
    }

    /// Whether the window is in native full screen (its own Space). Useful to tell "the user
    /// took it full screen" apart from an ordinary move/resize in `onUserChange`.
    public func isFullScreen(_ window: TargetWindow) -> Bool {
        AX.bool(window.element, AXName.fullScreen) == true
    }

    /// Puts the window back into native full screen, e.g. when restoring a window that was
    /// full screen before a session snapped it. Returns immediately; macOS animates it.
    public func enterFullScreen(_ window: TargetWindow) throws {
        guard AccessibilityAccess.isTrusted else { throw TilingError.notTrusted }
        let error = AX.setBool(window.element, AXName.fullScreen, true)
        guard error == .success else { throw Self.failure(error, "enter full screen", window) }
    }

    /// Brings the window's app to the front and raises the window.
    public func focus(_ window: TargetWindow) {
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            Self.activate(app, appElement: AX.application(window.pid))
        }
        AX.perform(window.element, AXName.raiseAction)
        AX.setBool(window.element, AXName.main, true)
    }

    // MARK: Private: setFrame steps

    /// Size → position → size, with `AXEnhancedUserInterface` off for the duration.
    private func applyFrame(_ frame: CGRect, to window: TargetWindow) throws {
        let element = window.element
        let appElement = AX.application(window.pid)

        let enhancedUI = AX.bool(appElement, AXName.enhancedUserInterface) == true
        if enhancedUI { AX.setBool(appElement, AXName.enhancedUserInterface, false) }
        defer {
            if enhancedUI { AX.setBool(appElement, AXName.enhancedUserInterface, true) }
        }

        let target = ScreenGeometry.flipped(frame, primaryScreenHeight: Self.primaryScreenHeight)
        // If the app can't even be asked, assume settable and let the set report the error.
        guard AX.isSettable(element, AXName.position) ?? true else {
            throw TilingError.axFailure("\(window.appName) doesn't allow its window to be moved.")
        }
        // Fixed-size windows are still moved; the caller sees the size in the returned frame.
        let canResize = AX.isSettable(element, AXName.size) ?? true

        let firstSizeError = canResize ? AX.setSize(element, AXName.size, target.size) : .success
        let positionError = AX.setPoint(element, AXName.position, target.origin)
        guard positionError == .success else { throw Self.failure(positionError, "move the window", window) }
        if canResize {
            let secondSizeError = AX.setSize(element, AXName.size, target.size)
            if secondSizeError != .success, firstSizeError != .success {
                throw Self.failure(secondSizeError, "resize the window", window)
            }
        }
    }

    /// Reads the frame back, giving apps that apply changes a beat late up to ~0.5 s.
    private func settledFrame(of window: TargetWindow, target: CGRect) async throws -> CGRect {
        guard var current = readFrame(of: window) else { throw Self.failure(.invalidUIElement, "read the window frame", window) }
        if ScreenGeometry.approximatelyEqual(current, target) { return current }

        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(500)
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard let next = readFrame(of: window) else { throw Self.failure(.invalidUIElement, "read the window frame", window) }
            if ScreenGeometry.approximatelyEqual(next, target) || next == current { return next }
            current = next
        }
        return current
    }

    private func readFrame(of window: TargetWindow) -> CGRect? {
        frame(of: window)
    }

    /// Polls until `condition` holds and the window frame has stopped changing for ~200 ms
    /// (and, if given, differs from `initialFrame`), or `timeout` passes. Returns early if
    /// the window disappears.
    private func waitUntilSettled(
        _ element: AXUIElement,
        timeout: Duration,
        leaving initialFrame: CGRect? = nil,
        until condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var previous: CGRect?
        var stableReads = 0
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let (current, error) = AX.frame(element)
            if error == .invalidUIElement { return }
            var hasLeftStart = true
            if let initialFrame {
                hasLeftStart = current.map { !ScreenGeometry.approximatelyEqual($0, initialFrame) } ?? false
            }
            if condition(), hasLeftStart, let current, current == previous {
                stableReads += 1
                if stableReads >= 2 { return }
            } else {
                stableReads = 0
            }
            previous = current
        }
    }

    // MARK: Private: helpers

    private struct WindowPick {
        var window: AXUIElement?
        var isFocused = false
        var notTrusted = false
    }

    /// Focused window → main window → first standard window (non-minimized preferred).
    private static func pickWindow(of app: AXUIElement) -> WindowPick {
        let (focused, focusedError) = AX.element(app, AXName.focusedWindow)
        switch focusedError {
        case .apiDisabled: return WindowPick(notTrusted: true)
        case .cannotComplete: return WindowPick() // Busy (still launching, or hung): try next poll.
        default: break
        }
        if let focused, isSnappable(focused) { return WindowPick(window: focused, isFocused: true) }

        if let main = AX.element(app, AXName.mainWindow).element, isSnappable(main) {
            return WindowPick(window: main)
        }

        let candidates = AX.elements(app, AXName.windows).filter { isSnappable($0) }
        let onScreen = candidates.first { AX.bool($0, AXName.minimized) != true }
        return WindowPick(window: onScreen ?? candidates.first)
    }

    /// A regular app/document window: not a dialog, sheet, floating panel or tiny helper.
    private static func isSnappable(_ window: AXUIElement) -> Bool {
        guard AX.string(window, AXName.role) == AXName.windowRole else { return false }
        // Some apps leave the subrole unset on ordinary windows; anything explicit must be standard.
        if let subrole = AX.string(window, AXName.subrole), !subrole.isEmpty,
           subrole != AXName.standardWindowSubrole {
            return false
        }
        if let size = AX.size(window, AXName.size),
           size.width < minimumSnappableSize.width || size.height < minimumSnappableSize.height {
            return false
        }
        return true
    }

    /// Cooperative activation (works while we're active), plus the Accessibility route,
    /// which works even when we aren't.
    private static func activate(_ app: NSRunningApplication, appElement: AXUIElement) {
        if app.isHidden { app.unhide() }
        NSApplication.shared.yieldActivation(to: app)
        app.activate(from: .current, options: [])
        AX.setBool(appElement, AXName.frontmost, true)
    }

    /// Re-opening a running app sends it a reopen ('rapp') event, as a Dock click does.
    private static func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    /// A running instance of the bundle at `appURL`, matched by bundle identifier
    /// (preferring the instance launched from that exact bundle), else by bundle path.
    private static func runningInstance(of appURL: URL) -> NSRunningApplication? {
        let targetPath = normalizedPath(appURL)
        let isSameBundle = { (app: NSRunningApplication) in
            app.bundleURL.map(normalizedPath) == targetPath
        }
        let candidates: [NSRunningApplication]
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        } else {
            candidates = NSWorkspace.shared.runningApplications.filter(isSameBundle)
        }
        let live = candidates.filter { !$0.isTerminated }
        return live.first(where: isSameBundle) ?? live.first
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func displayName(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleURL.map(displayName(ofBundleAt:)) ?? app.bundleIdentifier ?? "The app"
    }

    private static func displayName(ofBundleAt url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func failure(_ error: AXError, _ action: String, _ window: TargetWindow) -> TilingError {
        let app = window.appName
        switch error {
        case .apiDisabled:
            return .notTrusted
        case .invalidUIElement:
            return .axFailure("\(app)'s window was closed.")
        case .cannotComplete:
            return .axFailure("\(app) didn't respond when asked to \(action).")
        case .attributeUnsupported, .actionUnsupported, .notImplemented:
            return .axFailure("\(app) doesn't support being asked to \(action).")
        default:
            return .axFailure("Couldn't \(action) for \(app) (AXError \(error.rawValue)).")
        }
    }
}

/// Private but long-stable HIServices call (used by most window managers) that maps an AX
/// window element to its window-server number. There is no public equivalent.
@_silgen_name("_AXUIElementGetWindow")
private nonisolated func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
