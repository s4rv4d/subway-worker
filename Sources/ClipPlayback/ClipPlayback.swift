import Observation
import SubwayWorkerCore
import SwiftUI

/// Shared playback controls, owned by the app and observed by the player views.
@Observable
public final class PlaybackState {
    public var isMuted: Bool = true
    /// 0...1, applied when not muted.
    public var volume: Double = 0.5
    public var isPaused: Bool = false
    /// Set by the app while the clip is out of sight (e.g. hidden because you switched
    /// apps). Holds playback without touching the user's own play/pause choice.
    public var isSuspended: Bool = false
    /// Whether playback should actually be held right now.
    public var isEffectivelyPaused: Bool { isPaused || isSuspended }

    /// Human-readable name of what's playing right now (file name, "YouTube …").
    public internal(set) var nowPlaying: String?
    /// The last playback problem worth showing (unsupported file, empty folder, embed blocked…).
    /// Cleared when a new source starts playing successfully.
    public internal(set) var errorMessage: String?

    /// Bumped by `skip()`. Folder playback advances to the next clip when it changes.
    public private(set) var skipRequests: Int = 0

    public init() {}

    public func skip() { skipRequests += 1 }

    /// Forgets the previous clip's title and error. Call when switching sources, so a
    /// stale error card doesn't linger over a source that never reports status
    /// (the built-in templates).
    public func resetStatus() {
        nowPlaying = nil
        errorMessage = nil
    }
}

/// Fills its frame with the clip, cropped to fill (never letterboxed), looping forever.
/// Handles `.file`, `.folder` and `.youtube`; `.template` renders plain black because
/// templates are drawn by the ClipTemplates module.
public struct ClipPlayerView: View {
    let source: ClipSource
    let state: PlaybackState

    public init(source: ClipSource, state: PlaybackState) {
        self.source = source
        self.state = state
    }

    public var body: some View {
        ZStack {
            Color.black
            switch source {
            case .file, .folder:
                VideoPlayerRepresentable(source: source, state: state)
                    .id(source)
            case .youtube(let link):
                YouTubePlayerRepresentable(link: link, state: state)
                    .id(source)
                    .allowsHitTesting(false)
            case .template:
                Color.black
            }
        }
        .clipped()
    }
}

/// Re-arming `withObservationTracking` helper so live state changes apply even if
/// SwiftUI doesn't call `updateNSView`.
@MainActor
final class StateTracker {
    private var active = true

    func start(_ apply: @escaping @MainActor () -> Void) {
        guard active else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.start(apply)
            }
        }
    }

    func stop() { active = false }
}
