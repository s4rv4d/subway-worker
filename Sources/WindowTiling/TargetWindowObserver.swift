import AppKit
import ApplicationServices
import SubwayWorkerCore

/// Watches a target window for moves/resizes made by the user, and for it closing.
public final class TargetWindowObserver {
    /// The frame we last applied programmatically. Change events whose resulting frame
    /// is within ±4pt of this are treated as our own echo and not reported.
    ///
    /// `WindowTiler.setFrame(_:of:)` sets this automatically to the frame it ended up with.
    public var expectedFrame: CGRect?

    /// Quiet period after the last moved/resized event before the frame is read and reported.
    static let debounceDelay: Duration = .milliseconds(250)

    private let window: TargetWindow
    private var onUserChange: ((CGRect) -> Void)?
    private var onClose: (() -> Void)?
    private var onMinimizedChange: ((Bool) -> Void)?

    private var axObserver: AXObserver?
    /// What the C callback's refcon points at. Holds `self` weakly, so a callback can never
    /// reach a deallocated (or deinitializing) observer.
    private var relay: ObserverRelay?
    private var registeredNotifications: [String] = []
    private var terminationToken: (any NSObjectProtocol)?
    private var debounceTask: Task<Void, Never>?
    private var isInvalidated = false
    private var didClose = false

    /// - Parameters:
    ///   - onUserChange: Called on the main actor, debounced (~250 ms after the last
    ///     moved/resized event), with the window's new frame.
    ///   - onClose: Called once on the main actor when the window is destroyed or its
    ///     app terminates.
    ///   - onMinimizedChange: Called on the main actor with `true` when the window is
    ///     minimized to the Dock and `false` when it comes back.
    public init(
        window: TargetWindow,
        onUserChange: @escaping (CGRect) -> Void,
        onClose: @escaping () -> Void,
        onMinimizedChange: ((Bool) -> Void)? = nil
    ) throws {
        self.window = window
        self.onUserChange = onUserChange
        self.onClose = onClose
        self.onMinimizedChange = onMinimizedChange
        // From here on a throw runs deinit, which tears down whatever was set up.

        guard AccessibilityAccess.isTrusted else { throw TilingError.notTrusted }

        var created: AXObserver?
        let createError = AXObserverCreate(window.pid, axObserverCallback, &created)
        guard createError == .success, let observer = created else {
            throw createError == .apiDisabled
                ? TilingError.notTrusted
                : TilingError.axFailure("Couldn't watch \(window.appName)'s window (AXError \(createError.rawValue)).")
        }
        axObserver = observer

        let relay = ObserverRelay(owner: self)
        self.relay = relay
        let refcon = Unmanaged.passUnretained(relay).toOpaque()
        for name in [AXName.movedNotification, AXName.resizedNotification, AXName.destroyedNotification,
                     AXName.miniaturizedNotification, AXName.deminiaturizedNotification] {
            switch AXObserverAddNotification(observer, window.element, name as CFString, refcon) {
            case .success, .notificationAlreadyRegistered:
                registeredNotifications.append(name)
            case .apiDisabled:
                throw TilingError.notTrusted
            case .invalidUIElement:
                throw TilingError.noWindow(window.appName)
            default:
                continue // e.g. .notificationUnsupported: watch what we can.
            }
        }
        guard !registeredNotifications.isEmpty else {
            throw TilingError.axFailure("\(window.appName) doesn't report changes to its window.")
        }
        // Common modes, so events keep arriving while our own UI is tracking the mouse.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        let pid = window.pid
        terminationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let terminatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            guard terminatedPID == pid else { return }
            MainActor.assumeIsolated { self?.close() }
        }

        FrameChangeRegistry.register(self, for: window.element)

        // The app may have quit before we subscribed; report that after init returns.
        if NSRunningApplication(processIdentifier: pid)?.isTerminated ?? true {
            Task { [weak self] in self?.close() }
        }
    }

    isolated deinit {
        teardown(windowGone: didClose)
    }

    /// Stops observing. Safe to call more than once; no callbacks fire afterwards.
    public func invalidate() {
        teardown(windowGone: didClose)
    }

    // MARK: Events

    fileprivate func handleAXNotification(_ name: String) {
        guard !isInvalidated else { return }
        switch name {
        case AXName.destroyedNotification:
            close()
        case AXName.movedNotification, AXName.resizedNotification:
            scheduleReport()
        case AXName.miniaturizedNotification:
            onMinimizedChange?(true)
        case AXName.deminiaturizedNotification:
            onMinimizedChange?(false)
        default:
            break
        }
    }

    private func scheduleReport() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: TargetWindowObserver.debounceDelay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.reportChangeIfNeeded()
        }
    }

    private func reportChangeIfNeeded() {
        debounceTask = nil
        guard !isInvalidated else { return }

        // Mid-drag (mouse still down), or we're moving it ourselves: look again later.
        if NSEvent.pressedMouseButtons & 1 != 0 || FrameChangeRegistry.isChanging(window.element) {
            scheduleReport()
            return
        }

        let (axFrame, error) = AX.frame(window.element)
        guard let axFrame else {
            if error == .invalidUIElement { close() }
            return
        }
        let frame = ScreenGeometry.flipped(axFrame, primaryScreenHeight: WindowTiler.primaryScreenHeight)
        if let expectedFrame, ScreenGeometry.approximatelyEqual(frame, expectedFrame) { return }
        onUserChange?(frame)
    }

    /// Fires `onClose` at most once, after tearing everything down.
    private func close() {
        guard !isInvalidated else { return }
        let handler = onClose
        didClose = true
        teardown(windowGone: true)
        handler?()
    }

    /// - Parameter windowGone: Skip per-notification removal (an IPC round trip that can
    ///   only fail once the window or its app is gone).
    private func teardown(windowGone: Bool) {
        guard !isInvalidated else { return }
        isInvalidated = true

        debounceTask?.cancel()
        debounceTask = nil
        onUserChange = nil
        onClose = nil
        onMinimizedChange = nil

        if let terminationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationToken)
            self.terminationToken = nil
        }
        FrameChangeRegistry.unregister(ObjectIdentifier(self))

        if let axObserver {
            if !windowGone {
                for name in registeredNotifications {
                    AXObserverRemoveNotification(axObserver, window.element, name as CFString)
                }
            }
            // After this no AX callback can be delivered: callbacks only run on the main
            // run loop, and we are on the main thread.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        registeredNotifications.removeAll()

        // We may be inside this observer's own callback (e.g. onClose → invalidate), so
        // don't free the AXObserver or the relay until the callout has unwound.
        let retained: [AnyObject] = [axObserver as AnyObject?, relay as AnyObject?].compactMap { $0 }
        axObserver = nil
        relay = nil
        DeferredRelease(retained).releaseOnNextMainTurn()
    }
}

/// Target of the AX callback's refcon (passed unretained; owned by the observer and
/// released only after its run loop source is removed).
private final class ObserverRelay {
    weak var owner: TargetWindowObserver?

    init(owner: TargetWindowObserver) {
        self.owner = owner
    }
}

/// C callback for the AXObserver. It can't capture context and isn't actor-isolated; the
/// observer's run loop source is on the main run loop, so it always runs on the main thread.
private nonisolated func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let name = notification as String
    let relayAddress = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: relayAddress) else { return }
        let relay = Unmanaged<ObserverRelay>.fromOpaque(pointer).takeUnretainedValue()
        relay.owner?.handleAXNotification(name)
    }
}
