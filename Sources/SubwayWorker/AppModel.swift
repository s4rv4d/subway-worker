import AppKit
import ClipPlayback
import Observation
import SubwayWorkerCore
import UniformTypeIdentifiers
import WindowTiling

/// An app you can lock in on.
struct AppChoice: Identifiable, Hashable {
    /// Bundle identifier, or the bundle path for the odd app without one.
    let id: String
    let name: String
    let bundleURL: URL?
    let processIdentifier: pid_t?
    let icon: NSImage

    var runningApplication: NSRunningApplication? {
        if let processIdentifier, let app = NSRunningApplication(processIdentifier: processIdentifier), !app.isTerminated {
            return app
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    static func == (lhs: AppChoice, rhs: AppChoice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(running app: NSRunningApplication) {
        id = app.bundleIdentifier ?? app.bundleURL?.path ?? "pid-\(app.processIdentifier)"
        name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
        bundleURL = app.bundleURL
        processIdentifier = app.processIdentifier
        icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
    }

    init?(bundleAt url: URL) {
        guard let bundle = Bundle(url: url) else { return nil }
        id = bundle.bundleIdentifier ?? url.path
        name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        bundleURL = url
        processIdentifier = nil
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// What the clip does while you're in an app other than the one you locked in on.
enum SwitchAwayBehavior: String, Codable, CaseIterable, Identifiable {
    /// Acts like part of the locked-in app: other apps' windows cover it, and it
    /// comes back to the front with the app.
    case goBehind
    /// Disappears and pauses until you're back in the locked-in app.
    case hide
    /// Floats above every window, whatever app you're in.
    case stayOnTop

    var id: Self { self }

    var title: String {
        switch self {
        case .goBehind: "Go behind other windows"
        case .hide: "Hide and pause"
        case .stayOnTop: "Stay on top"
        }
    }
}

/// What fills the screen behind the split while a session runs.
enum FrameStyle: String, Codable, CaseIterable, Identifiable {
    case bricks
    case black
    case off

    var id: Self { self }

    var title: String {
        switch self {
        case .bricks: "Brick wall"
        case .black: "Black"
        case .off: "None"
        }
    }
}

/// Everything the UI binds to. One instance for the whole app.
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Persisted preferences

    var clipSource: ClipSource {
        didSet {
            Defaults.save(clipSource, for: .clipSource)
            if clipSource != oldValue { playback.resetStatus() }
            refreshFolderClipCount()
        }
    }
    var placement: ClipPlacement { didSet { Defaults.save(placement, for: .placement) } }
    var sizing: ClipSizing { didSet { Defaults.save(sizing, for: .sizing) } }
    var keepSnapped: Bool { didSet { Defaults.save(keepSnapped, for: .keepSnapped) } }
    var switchAwayBehavior: SwitchAwayBehavior {
        didSet {
            Defaults.save(switchAwayBehavior, for: .switchAwayBehavior)
            session.updatePanelPresence()
        }
    }
    var restoreOnEnd: Bool { didSet { Defaults.save(restoreOnEnd, for: .restoreOnEnd) } }
    /// The backdrop behind the split; any style but `.off` also leaves a small gap around
    /// and between the two sides.
    var frameStyle: FrameStyle {
        didSet {
            Defaults.save(frameStyle, for: .frameStyle)
            session.relayout()
        }
    }
    var selectedAppID: String? { didSet { Defaults.save(selectedAppID, for: .lastAppID) } }

    // MARK: Live state

    private(set) var runningApps: [AppChoice] = []
    /// Apps picked through "Other app…" that aren't running yet.
    private(set) var pickedApps: [AppChoice] = []
    private(set) var isTrusted = AccessibilityAccess.isTrusted
    /// How many playable clips the chosen folder has (nil unless the source is a folder).
    private(set) var folderClipCount: Int?
    let playback = PlaybackState()
    @ObservationIgnored private(set) lazy var session = SessionController(model: self)

    var allApps: [AppChoice] {
        let runningIDs = Set(runningApps.map(\.id))
        return pickedApps.filter { !runningIDs.contains($0.id) } + runningApps
    }

    var selectedApp: AppChoice? {
        guard let selectedAppID else { return nil }
        return allApps.first { $0.id == selectedAppID }
    }

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        clipSource = Defaults.load(ClipSource.self, for: .clipSource) ?? .default
        placement = Defaults.load(ClipPlacement.self, for: .placement) ?? .automatic
        sizing = Defaults.load(ClipSizing.self, for: .sizing) ?? .automatic
        keepSnapped = Defaults.load(Bool.self, for: .keepSnapped) ?? true
        switchAwayBehavior = Defaults.load(SwitchAwayBehavior.self, for: .switchAwayBehavior) ?? .goBehind
        restoreOnEnd = Defaults.load(Bool.self, for: .restoreOnEnd) ?? true
        frameStyle = Defaults.load(FrameStyle.self, for: .frameStyle) ?? .bricks
        selectedAppID = Defaults.load(String.self, for: .lastAppID)
        playback.isMuted = Defaults.load(Bool.self, for: .muted) ?? true
        playback.volume = Defaults.load(Double.self, for: .volume) ?? 0.5

        refreshFolderClipCount()
        refreshRunningApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningApps() }
            })
        }
        startTrustPolling()
    }

    // MARK: Apps

    func refreshRunningApps() {
        let me = Bundle.main.bundleIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != me && !$0.isTerminated }
            .map(AppChoice.init(running:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Other app…": pick any .app, even if it isn't running yet.
    func pickOtherApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to lock in on"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let choice = AppChoice(bundleAt: url) else { return }
        // Snapping ourselves would just hang on our own Accessibility calls.
        guard choice.id != Bundle.main.bundleIdentifier else {
            NSSound.beep()
            return
        }
        if !allApps.contains(choice) { pickedApps.append(choice) }
        selectedAppID = choice.id
    }

    func refreshFolderClipCount() {
        if case .folder(let url) = clipSource {
            folderClipCount = VideoLibrary.videos(in: url).count
        } else {
            folderClipCount = nil
        }
    }

    // MARK: Accessibility

    private func startTrustPolling() {
        Task { [weak self] in
            while let self, !self.isTrusted {
                try? await Task.sleep(for: .seconds(1))
                self.isTrusted = AccessibilityAccess.isTrusted
            }
        }
    }

    func requestAccessibility() {
        isTrusted = AccessibilityAccess.requestAccess()
        if !isTrusted { AccessibilityAccess.openSystemSettings() }
    }

    // MARK: Session

    /// Snaps the selected app and starts the clip. Returns whether the session is running.
    @discardableResult
    func lockIn() async -> Bool {
        guard let app = selectedApp else { return false }
        await session.start(app)
        return session.isActive
    }

    // MARK: Playback controls (persisted)

    func toggleMute() {
        playback.isMuted.toggle()
        Defaults.save(playback.isMuted, for: .muted)
    }

    func setVolume(_ volume: Double) {
        playback.volume = volume
        if playback.isMuted, volume > 0 { toggleMute() }
        Defaults.save(volume, for: .volume)
    }

    func togglePause() { playback.isPaused.toggle() }

    /// Moves the clip to the opposite side and re-snaps.
    func swapSides() {
        let screenSize = session.screenSize ?? NSScreen.main?.visibleFrame.size ?? CGSize(width: 16, height: 9)
        let current = placement.resolved(for: screenSize)
        placement = ClipPlacement(rawValue: current.flipped.rawValue) ?? .automatic
        session.relayout()
    }

    // MARK: Picking clips

    func chooseVideoFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a gameplay clip"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { clipSource = .file(url) }
    }

    func chooseVideoFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of clips to shuffle"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { clipSource = .folder(url) }
    }

    /// Accepts a dropped/pasted video, folder, or YouTube link. Returns whether it was usable.
    @discardableResult
    func useClip(from url: URL) -> Bool {
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            if isDirectory.boolValue {
                clipSource = .folder(url)
                return true
            }
            guard VideoLibrary.isSupportedVideo(url) else { return false }
            clipSource = .file(url)
            return true
        }
        guard let link = YouTubeLink(string: url.absoluteString) else { return false }
        clipSource = .youtube(link)
        return true
    }

    @discardableResult
    func useYouTubeLinkFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string),
              let link = YouTubeLink(string: text) else { return false }
        clipSource = .youtube(link)
        return true
    }
}

// MARK: - UserDefaults plumbing

private enum Defaults {
    enum Key: String {
        case clipSource, placement, sizing, keepSnapped, switchAwayBehavior, restoreOnEnd, frameStyle, lastAppID, muted, volume
    }

    static func save<T: Encodable>(_ value: T?, for key: Key) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
            return
        }
        UserDefaults.standard.set(data, forKey: key.rawValue)
    }

    static func load<T: Decodable>(_ type: T.Type, for key: Key) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
