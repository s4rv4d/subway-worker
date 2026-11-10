import AppKit
import ApplicationServices

/// Accessibility attribute, action and notification names. Plain strings (rather than the
/// imported `kAX…` globals) so they are trivially Sendable and usable from nonisolated code.
nonisolated enum AXName {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let windows = "AXWindows"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let main = "AXMain"
    static let minimized = "AXMinimized"
    static let fullScreen = "AXFullScreen"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let frontmost = "AXFrontmost"
    static let enhancedUserInterface = "AXEnhancedUserInterface"

    static let windowRole = "AXWindow"
    static let standardWindowSubrole = "AXStandardWindow"

    static let raiseAction = "AXRaise"

    static let movedNotification = "AXMoved"
    static let resizedNotification = "AXResized"
    static let destroyedNotification = "AXUIElementDestroyed"
    static let miniaturizedNotification = "AXWindowMiniaturized"
    static let deminiaturizedNotification = "AXWindowDeminiaturized"
}

/// Thin, typed wrappers over the AXUIElement C API.
enum AX {
    /// Upper bound for any single AX request, so a hung app can't freeze the main thread.
    static let messagingTimeout: Float = 1.0

    /// The application element for `pid`, with the messaging timeout applied.
    static func application(_ pid: pid_t) -> AXUIElement {
        bounded(AXUIElementCreateApplication(pid))
    }

    // MARK: Reading

    static func copy(_ element: AXUIElement, _ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (copy(element, attribute).value as? NSNumber)?.boolValue
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute).value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> (element: AXUIElement?, error: AXError) {
        let (value, error) = copy(element, attribute)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        return (bounded(unsafeDowncast(value, to: AXUIElement.self)), error)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let array = copy(element, attribute).value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? bounded(unsafeDowncast(item, to: AXUIElement.self)) : nil
        }
    }

    /// Element refs don't inherit the app element's timeout (the default is ~6 s), so every
    /// element we hand out gets its own bound.
    static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(copy(element, attribute).value, ofType: .cgPoint) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(copy(element, attribute).value, ofType: .cgSize) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// The element's frame in Accessibility coordinates (origin top-left of the primary
    /// display, y down). On failure, `error` is the first AX error encountered.
    static func frame(_ element: AXUIElement) -> (frame: CGRect?, error: AXError) {
        let position = copy(element, AXName.position)
        guard position.error == .success else { return (nil, position.error) }
        let size = copy(element, AXName.size)
        guard size.error == .success else { return (nil, size.error) }

        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard let positionValue = axValue(position.value, ofType: .cgPoint),
              let sizeValue = axValue(size.value, ofType: .cgSize),
              AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &extent)
        else { return (nil, .failure) }
        return (CGRect(origin: origin, size: extent), .success)
    }

    /// Whether `attribute` can be written, or nil if the app couldn't be asked.
    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success ? settable.boolValue : nil
    }

    // MARK: Writing

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ flag: Bool) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, flag as CFTypeRef)
    }

    @discardableResult
    static func setPoint(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ attribute: String, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    // MARK: Private

    private static func axValue(_ value: CFTypeRef?, ofType type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}

/// Links `WindowTiler.setFrame` with live `TargetWindowObserver`s of the same window, so
/// the moves/resizes we make ourselves are never reported as the user's.
enum FrameChangeRegistry {
    private struct Registration {
        let id: ObjectIdentifier
        let element: AXUIElement
        weak var observer: TargetWindowObserver?
    }

    /// Windows a `setFrame` is currently working on (one entry per in-flight call).
    private static var inFlight: [AXUIElement] = []
    private static var registrations: [Registration] = []

    static func beginProgrammaticChange(_ element: AXUIElement) {
        inFlight.append(element)
    }

    static func endProgrammaticChange(_ element: AXUIElement) {
        if let index = inFlight.firstIndex(where: { CFEqual($0, element) }) {
            inFlight.remove(at: index)
        }
    }

    static func isChanging(_ element: AXUIElement) -> Bool {
        inFlight.contains { CFEqual($0, element) }
    }

    /// Records the frame a programmatic change ended with as every observer's `expectedFrame`.
    static func didApply(_ frame: CGRect, to element: AXUIElement) {
        registrations.removeAll { $0.observer == nil }
        for registration in registrations where CFEqual(registration.element, element) {
            registration.observer?.expectedFrame = frame
        }
    }

    static func register(_ observer: TargetWindowObserver, for element: AXUIElement) {
        registrations.removeAll { $0.observer == nil }
        registrations.append(Registration(id: ObjectIdentifier(observer), element: element, observer: observer))
    }

    static func unregister(_ id: ObjectIdentifier) {
        registrations.removeAll { $0.id == id || $0.observer == nil }
    }
}

/// Keeps objects alive until a later main-queue turn. Used so an `AXObserver` torn down from
/// inside its own callback isn't freed while the Accessibility framework is still using it.
nonisolated final class DeferredRelease: @unchecked Sendable {
    private let objects: [AnyObject]

    init(_ objects: [AnyObject]) {
        self.objects = objects
    }

    func releaseOnNextMainTurn() {
        DispatchQueue.main.async { withExtendedLifetime(self) {} }
    }
}
