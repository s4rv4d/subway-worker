import AppKit
import SubwayWorkerCore
import SwiftUI
import WebKit

/// App identity used for YouTube's API client identification (HTTP Referer / `origin`).
///
/// YouTube requires embedded-player clients to send a Referer. WKWebView's
/// `loadHTMLString(_, baseURL: nil)` sends none, which produces Error 153. YouTube's
/// "Required Minimum Functionality" policy says to load bundled HTML with a base URL of
/// `https://<app id>` (Apple bundle id on macOS/iOS).
public enum YouTubeEmbedIdentity {
    public static let fallbackBundleID = "dev.sarvad.SubwayWorker"

    public static var bundleID: String {
        if let id = Bundle.main.bundleIdentifier, id.contains(".") { return id }
        return fallbackBundleID
    }

    /// e.g. `https://dev.sarvad.subwayworker` (host names are case-insensitive; keep it lowercase).
    public static var origin: String { "https://" + bundleID.lowercased() }
}

/// A web view that never receives clicks, scrolls or focus.
final class NonInteractiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func scrollWheel(with event: NSEvent) {}
}

/// Weak trampoline: WKUserContentController retains its handlers strongly.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlayerCoordinator?

    init(target: YouTubePlayerCoordinator) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only our own top-level page may talk to the app, never YouTube's frames.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == URL(string: YouTubeEmbedIdentity.origin)?.host
        else { return }
        target?.handle(message.body)
    }
}

@MainActor
final class YouTubePlayerCoordinator: NSObject, WKNavigationDelegate {
    static let handlerName = "sw"

    let link: YouTubeLink
    let state: PlaybackState
    weak var webView: WKWebView?
    private let tracker = StateTracker()
    private var pageLoaded = false
    private var stopped = false
    private var bufferingTask: Task<Void, Never>?

    init(link: YouTubeLink, state: PlaybackState) {
        self.link = link
        self.state = state
        super.init()
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing survives the session: no cookies, cache or storage written to disk.
        config.websiteDataStore = .nonPersistent()
        // No Safe Browsing lookups; the only page we load is our own.
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptHandler(target: self), name: Self.handlerName)

        let view = NonInteractiveWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .black
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        webView = view

        state.errorMessage = nil
        state.nowPlaying = nil
        view.loadHTMLString(Self.html(for: link, state: state), baseURL: URL(string: YouTubeEmbedIdentity.origin))
        tracker.start { [weak self] in self?.pushControls() }
        return view
    }

    /// Reads state (so observation tracks it) and pushes it to the page.
    func pushControls() {
        let muted = state.isMuted
        let volume = Int((min(max(state.volume, 0), 1) * 100).rounded())
        let paused = state.isEffectivelyPaused
        guard pageLoaded, !stopped, let webView else { return }
        webView.evaluateJavaScript("window.sw && window.sw.set(\(muted), \(volume), \(paused));", completionHandler: nil)
    }

    func teardown() {
        guard !stopped else { return }
        stopped = true
        tracker.stop()
        bufferingTask?.cancel()
        bufferingTask = nil
        guard let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    // MARK: Bridge

    func handle(_ body: Any) {
        guard !stopped, let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "playing":
            let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            setBuffering(false)
            state.nowPlaying = (title?.isEmpty == false) ? title : "YouTube"
            state.errorMessage = nil
        case "buffering":
            setBuffering(true)
        case "paused":
            setBuffering(false)
        case "error":
            let code = (dict["code"] as? Int) ?? Int((dict["code"] as? Double) ?? -1)
            setBuffering(false)
            state.nowPlaying = nil
            state.errorMessage = Self.message(forErrorCode: code)
        default:
            break
        }
    }

    /// Stalls only count once they last: the loop's own seek back to the start buffers for
    /// an instant every time round, and that must not flash the loading skeleton.
    private func setBuffering(_ buffering: Bool) {
        bufferingTask?.cancel()
        bufferingTask = nil
        guard buffering else {
            state.isBuffering = false
            return
        }
        bufferingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.state.isBuffering = true
        }
    }

    static func message(forErrorCode code: Int) -> String {
        switch code {
        case 2: "That YouTube link has an invalid video ID."
        case 5: "YouTube's HTML5 player hit an error. Try again or use another link."
        case 100: "That YouTube video was removed or is private."
        case 101, 150: "The video's owner doesn't allow embedding. Try another link."
        case 152, 153: "YouTube rejected the embed (player configuration / missing referrer, error \(code)). Try another link."
        default: "YouTube playback error (code \(code))."
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped else { return }
        pageLoaded = true
        pushControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        state.errorMessage = "Couldn't load YouTube: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        state.errorMessage = "Couldn't load YouTube: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // YouTube's player iframe loads whatever playback needs.
        if let frame = navigationAction.targetFrame, !frame.isMainFrame { return .allow }
        // The top-level page is our bundled HTML and stays that way: no clicks, scripts or
        // popups (targetFrame nil) can take it anywhere else.
        let url = navigationAction.request.url
        let isOurPage = url?.host?.lowercased() == URL(string: YouTubeEmbedIdentity.origin)?.host || url?.scheme == "about"
        return isOurPage ? .allow : .cancel
    }

    // MARK: HTML

    static func html(for link: YouTubeLink, state: PlaybackState) -> String {
        let volume = Int((min(max(state.volume, 0), 1) * 100).rounded())
        return template
            .replacingOccurrences(of: "__VIDEO_ID__", with: link.videoID)
            .replacingOccurrences(of: "__START__", with: String(max(link.startSeconds ?? 0, 0)))
            .replacingOccurrences(of: "__ASPECT__", with: String(link.assumedAspectRatio))
            .replacingOccurrences(of: "__ORIGIN__", with: YouTubeEmbedIdentity.origin)
            .replacingOccurrences(of: "__MUTED__", with: state.isMuted ? "true" : "false")
            .replacingOccurrences(of: "__VOLUME__", with: String(volume))
            .replacingOccurrences(of: "__PAUSED__", with: state.isEffectivelyPaused ? "true" : "false")
    }

    private static let template = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="strict-origin-when-cross-origin">
    <style>
      html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; pointer-events: none; }
      #stage { position: fixed; left: 0; top: 0; right: 0; bottom: 0; overflow: hidden; background: #000; pointer-events: none; }
      #player { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); border: 0; background: #000; pointer-events: none; }
    </style>
    </head>
    <body>
    <div id="stage"><div id="player"></div></div>
    <script>
      var ASPECT = __ASPECT__, START = __START__;
      var desired = { muted: __MUTED__, volume: __VOLUME__, paused: __PAUSED__ };
      var player = null, ready = false;

      function post(msg) {
        try { window.webkit.messageHandlers.sw.postMessage(msg); } catch (e) {}
      }

      function layout() {
        var el = document.getElementById('player');
        if (!el) return;
        var vw = window.innerWidth, vh = window.innerHeight;
        var w, h;
        if (vw / vh > ASPECT) { w = vw; h = vw / ASPECT; } else { h = vh; w = vh * ASPECT; }
        w = Math.ceil(w * 1.02); h = Math.ceil(h * 1.02);
        el.style.width = w + 'px';
        el.style.height = h + 'px';
      }
      window.addEventListener('resize', layout);
      layout();

      function applyDesired() {
        if (!ready || !player) return;
        try {
          player.setVolume(desired.volume);
          if (desired.muted) player.mute(); else player.unMute();
          if (desired.paused) player.pauseVideo(); else player.playVideo();
        } catch (e) {}
      }
      window.sw = { set: function (m, v, p) { desired = { muted: m, volume: v, paused: p }; applyDesired(); } };

      function onYouTubeIframeAPIReady() {
        player = new YT.Player('player', {
          width: '100%', height: '100%',
          videoId: '__VIDEO_ID__',
          host: 'https://www.youtube-nocookie.com',
          playerVars: {
            autoplay: 1, controls: 0, disablekb: 1, fs: 0, rel: 0, iv_load_policy: 3,
            playsinline: 1, modestbranding: 1, start: START,
            mute: desired.muted ? 1 : 0,
            origin: '__ORIGIN__', widget_referrer: '__ORIGIN__'
          },
          events: {
            onReady: function () { ready = true; layout(); applyDesired(); },
            onStateChange: function (e) {
              if (e.data === YT.PlayerState.ENDED) {
                player.seekTo(START, true);
                player.playVideo();
              } else if (e.data === YT.PlayerState.PLAYING) {
                if (desired.paused) { player.pauseVideo(); }
                var title = '';
                try { title = player.getVideoData().title || ''; } catch (err) {}
                post({ type: 'playing', title: title });
              } else if (e.data === YT.PlayerState.BUFFERING) {
                post({ type: 'buffering' });
              } else if (e.data === YT.PlayerState.PAUSED) {
                post({ type: 'paused' });
              }
            },
            onError: function (e) { post({ type: 'error', code: e.data }); }
          }
        });
        layout();
      }
    </script>
    <script src="https://www.youtube.com/iframe_api"></script>
    </body>
    </html>
    """
}

struct YouTubePlayerRepresentable: NSViewRepresentable {
    let link: YouTubeLink
    let state: PlaybackState

    func makeCoordinator() -> YouTubePlayerCoordinator {
        YouTubePlayerCoordinator(link: link, state: state)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.pushControls()
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: YouTubePlayerCoordinator) {
        coordinator.teardown()
    }
}
