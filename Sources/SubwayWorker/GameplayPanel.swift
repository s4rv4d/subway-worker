import AppKit
import ClipPlayback
import ClipTemplates
import SubwayWorkerCore
import SwiftUI

/// The window that shows the clip. A non-activating panel: clicking its controls
/// never steals focus from the app you're working in.
final class GameplayPanel: NSPanel, NSWindowDelegate {
    /// Called when the user finishes dragging one of the panel's edges.
    var onUserResize: ((CGRect) -> Void)?

    init(model: AppModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Subway Worker"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        backgroundColor = .black
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        minSize = NSSize(width: 160, height: 160)
        delegate = self

        let hosting = NSHostingView(rootView: PanelRootView(model: model))
        // The session decides the panel's size, not the SwiftUI content.
        hosting.sizingOptions = []
        contentView = hosting
    }

    /// Never key, never main: keystrokes always stay with the app you're working in.
    /// (Buttons, menus and drops all work without key status.)
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Double-clicking the (invisible) title bar would otherwise zoom the panel.
    override func zoom(_ sender: Any?) {}

    func windowDidEndLiveResize(_ notification: Notification) {
        onUserResize?(frame)
    }
}

// MARK: - Panel content

struct PanelRootView: View {
    let model: AppModel
    @State private var isHovering = false
    @State private var isDropTargeted = false

    private var playback: PlaybackState { model.playback }

    var body: some View {
        ZStack {
            ClipView(source: model.clipSource, playback: playback)

            if let error = playback.errorMessage {
                ErrorCard(message: error)
                    .padding(16)
            }

            VStack {
                if isHovering, let nowPlaying = playback.nowPlaying ?? Optional(model.clipSource.displayName) {
                    Text(nowPlaying)
                        .font(.geistMono(11, .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                if isHovering {
                    PanelControls(model: model)
                        .padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 10)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .overlay {
                        Text("Drop a video, folder or YouTube link")
                            .font(.geist(13, .medium))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.background.opacity(0.85), in: .rect(cornerRadius: 10))
                            .padding(12)
                    }
                    .padding(10)
            }
        }
        .background(.black)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .background(HoverTracker(isHovering: $isHovering))
        .dropDestination(for: URL.self) { urls, _ in
            urls.contains { model.useClip(from: $0) }
        } isTargeted: { isDropTargeted = $0 }
    }
}

/// Picks the right renderer for a clip source.
struct ClipView: View {
    let source: ClipSource
    let playback: PlaybackState

    var body: some View {
        switch source {
        case .template(let template):
            TemplateClipView(template: template, isPaused: playback.isEffectivelyPaused)
        case .file, .folder, .youtube:
            ClipPlayerView(source: source, state: playback)
        }
    }
}

private struct PanelControls: View {
    let model: AppModel

    var body: some View {
        let playback = model.playback
        let sideBySide = model.session.resolvedPlacement.isSideBySide
        HStack(spacing: 2) {
            ControlButton(symbol: playback.isPaused ? "play.fill" : "pause.fill",
                          help: playback.isPaused ? "Play" : "Pause") { model.togglePause() }
            ControlButton(symbol: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          help: playback.isMuted ? "Unmute" : "Mute") { model.toggleMute() }
            if model.clipSource.supportsSkipping {
                ControlButton(symbol: "forward.fill", help: "Next clip") { playback.skip() }
            }
            ControlButton(symbol: sideBySide ? "arrow.left.arrow.right" : "arrow.up.arrow.down",
                          help: "Swap sides") { model.swapSides() }
            Menu {
                ClipMenuItems(model: model)
            } label: {
                Image(systemName: "film.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change clip")
            ControlButton(symbol: "xmark", help: "End session") {
                Task { await model.session.end(restore: model.restoreOnEnd) }
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct ControlButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Menu items for switching clips; shared by the panel and the menu bar.
struct ClipMenuItems: View {
    let model: AppModel

    var body: some View {
        Section("Built-in loops") {
            ForEach(ClipTemplate.allCases) { template in
                Toggle(isOn: Binding(
                    get: { model.clipSource == .template(template) },
                    set: { if $0 { model.clipSource = .template(template) } }
                )) {
                    Label(template.title, systemImage: template.symbolName)
                }
            }
        }
        Section("Your clips") {
            Button("Choose Video File…", systemImage: "film") { model.chooseVideoFile() }
            Button("Choose Folder to Shuffle…", systemImage: "folder") { model.chooseVideoFolder() }
            Button("Paste YouTube Link", systemImage: "play.rectangle") { model.useYouTubeLinkFromClipboard() }
        }
    }
}

private struct ErrorCard: View {
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.geist(13, .medium))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("Hover for controls, or drop another clip here.")
                .font(.geist(11.5))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(Theme.background.opacity(0.9), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.danger.opacity(0.5))
        }
    }
}

/// SwiftUI's `onHover` only fires while our app is active, but this panel lives next to
/// another app that has focus. An always-active tracking area works regardless.
private struct HoverTracker: NSViewRepresentable {
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { isHovering = $0 }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = { isHovering = $0 }
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
