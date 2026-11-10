import AVFoundation
import AppKit
import SubwayWorkerCore
import SwiftUI

/// NSView whose backing layer is an AVPlayerLayer (aspect-fill, black).
final class PlayerHostView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

}

/// Drives an AVQueuePlayer for a single looping file or a shuffled folder playlist.
@MainActor
final class VideoController {
    enum Mode {
        case file(URL)
        case folder(URL)
    }

    let player = AVQueuePlayer()
    private let mode: Mode
    private let state: PlaybackState
    private let tracker = StateTracker()

    private var looper: AVPlayerLooper?
    private var looperObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var currentItemID: ObjectIdentifier?

    private var playlist: [URL] = []
    private var playlistIndex = 0
    private var lastPlayed: URL?
    private var consecutiveFailures = 0
    private var lastSkip: Int
    private var stopped = false

    init(mode: Mode, state: PlaybackState) {
        self.mode = mode
        self.state = state
        self.lastSkip = state.skipRequests
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.actionAtItemEnd = .none
    }

    func start() {
        state.errorMessage = nil
        state.nowPlaying = nil
        applyControls()
        switch mode {
        case .file(let url): startFile(url)
        case .folder: startNextClip()
        }
        tracker.start { [weak self] in self?.applyControls() }
    }

    /// Applies mute/volume/pause (and skip requests). Reads state so observation tracks it.
    func applyControls() {
        guard !stopped else { return }
        player.isMuted = state.isMuted
        player.volume = Float(min(max(state.volume, 0), 1))
        let skips = state.skipRequests
        if skips != lastSkip {
            lastSkip = skips
            if case .folder = mode { startNextClip() }
        }
        if state.isEffectivelyPaused {
            player.pause()
        } else if player.currentItem != nil {
            player.play()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        tracker.stop()
        clearItemObservers()
        looperObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
    }

    // MARK: File

    private func startFile(_ url: URL) {
        // Local files only, even if the saved preference was tampered with.
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            state.errorMessage = "Video file not found: \(url.lastPathComponent)"
            return
        }
        let item = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: item)
        self.looper = looper
        looperObservation = looper.observe(\.status, options: [.initial, .new]) { [weak self] looper, _ in
            let status = looper.status
            let error = looper.error
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch status {
                case .ready:
                    self.state.errorMessage = nil
                    self.state.nowPlaying = url.lastPathComponent
                    self.applyControls()
                case .failed:
                    self.state.nowPlaying = nil
                    self.state.errorMessage = Self.failureMessage(for: url, error: error)
                default: break
                }
            }
        }
        applyControls()
    }

    // MARK: Folder

    private func reshuffle(folder: URL) -> Bool {
        let videos = VideoLibrary.videos(in: folder)
        guard !videos.isEmpty else {
            state.nowPlaying = nil
            state.errorMessage = "No .mp4/.mov/.m4v videos in \(folder.lastPathComponent)"
            return false
        }
        var shuffled = videos.shuffled()
        if shuffled.count > 1, shuffled.first == lastPlayed {
            shuffled.swapAt(0, shuffled.count - 1)
        }
        playlist = shuffled
        playlistIndex = 0
        return true
    }

    private func startNextClip() {
        guard !stopped, case .folder(let folder) = mode else { return }
        if playlistIndex >= playlist.count {
            guard reshuffle(folder: folder) else {
                clearItemObservers()
                player.removeAllItems()
                return
            }
        }
        let url = playlist[playlistIndex]
        playlistIndex += 1
        lastPlayed = url
        play(clip: url)
    }

    private func play(clip url: URL) {
        clearItemObservers()
        guard FileManager.default.fileExists(atPath: url.path) else {
            clipFailed(url, message: "Video file not found: \(url.lastPathComponent)")
            return
        }
        let item = AVPlayerItem(url: url)
        let id = ObjectIdentifier(item)
        currentItemID = id

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.currentItemID == id else { return }
                switch status {
                case .readyToPlay:
                    self.consecutiveFailures = 0
                    self.state.errorMessage = nil
                    self.state.nowPlaying = url.lastPathComponent
                case .failed:
                    self.clipFailed(url, message: Self.failureMessage(for: url, error: error))
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentItemID == id else { return }
                self.startNextClip()
            }
        })
        observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, self.currentItemID == id else { return }
                self.clipFailed(url, message: Self.failureMessage(for: url, error: error))
            }
        })

        player.removeAllItems()
        player.insert(item, after: nil)
        applyControls()
    }

    private func clipFailed(_ url: URL, message: String) {
        guard !stopped else { return }
        consecutiveFailures += 1
        state.nowPlaying = nil
        state.errorMessage = message
        clearItemObservers()
        // Give up once every clip in a full pass has failed, to avoid a hot loop.
        if consecutiveFailures >= max(playlist.count, 1) {
            player.removeAllItems()
            return
        }
        startNextClip()
    }

    private func clearItemObservers() {
        itemObservation = nil
        currentItemID = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    private static func failureMessage(for url: URL, error: Error?) -> String {
        let detail = error?.localizedDescription ?? "unsupported or corrupt file"
        return "Can't play \(url.lastPathComponent): \(detail)"
    }
}

struct VideoPlayerRepresentable: NSViewRepresentable {
    let source: ClipSource
    let state: PlaybackState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        let mode: VideoController.Mode
        switch source {
        case .folder(let url): mode = .folder(url)
        case .file(let url): mode = .file(url)
        default: mode = .file(URL(fileURLWithPath: "/dev/null"))
        }
        let controller = VideoController(mode: mode, state: state)
        view.playerLayer.player = controller.player
        context.coordinator.controller = controller
        controller.start()
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        // Reading state here registers SwiftUI observation; the controller also tracks it itself.
        context.coordinator.controller?.applyControls()
    }

    static func dismantleNSView(_ nsView: PlayerHostView, coordinator: Coordinator) {
        coordinator.controller?.stop()
        nsView.playerLayer.player = nil
        coordinator.controller = nil
    }

    @MainActor
    final class Coordinator {
        var controller: VideoController?
    }
}
