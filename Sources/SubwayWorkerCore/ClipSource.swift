import Foundation

/// What plays in the gameplay panel.
public enum ClipSource: Codable, Equatable, Hashable, Sendable {
    /// One local video, looped gaplessly.
    case file(URL)
    /// Every supported video in a folder, shuffled, looping the whole playlist.
    case folder(URL)
    /// A YouTube video played through the official embed player, looped.
    case youtube(YouTubeLink)
    /// A built-in procedural animation (no video needed).
    case template(ClipTemplate)

    public static let `default`: ClipSource = .template(.railRush)

    public var displayName: String {
        switch self {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .folder(let url): "\(url.lastPathComponent) (shuffle)"
        case .youtube(let link): link.isShort ? "YouTube Short \(link.videoID)" : "YouTube \(link.videoID)"
        case .template(let template): template.title
        }
    }

    /// Only folders can skip to another clip.
    public var supportsSkipping: Bool {
        if case .folder = self { return true }
        return false
    }
}

/// Built-in loops for when you don't have gameplay footage handy.
/// All original procedural art — no third-party game assets.
public enum ClipTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Endless runner through a dusk train yard: dodge trains, jump barriers, grab tokens.
    case railRush
    /// Pseudo-3D three-lane neon runner that dodges and jumps forever.
    case neonRunner
    /// A ball bouncing inside a spinning ring with a gap; it grows each hit until it escapes.
    case ringBounce
    /// The old-school bouncing screensaver badge. Will it hit the corner?
    case bouncingBadge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .railRush: "Rail Rush"
        case .neonRunner: "Neon Runner"
        case .ringBounce: "Ring Bounce"
        case .bouncingBadge: "Corner Hunter"
        }
    }

    public var blurb: String {
        switch self {
        case .railRush: "Dodge trains, grab tokens, forever"
        case .neonRunner: "Endless lane-dodging, zero effort"
        case .ringBounce: "Satisfying physics, growing ball"
        case .bouncingBadge: "Will it hit the corner this time?"
        }
    }

    /// SF Symbol shown in pickers.
    public var symbolName: String {
        switch self {
        case .railRush: "tram.fill"
        case .neonRunner: "figure.run"
        case .ringBounce: "circle.circle"
        case .bouncingBadge: "rectangle.on.rectangle.angled"
        }
    }
}

public enum VideoLibrary {
    /// Containers AVFoundation can play natively. (WebM/MKV are not supported.)
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func isSupportedVideo(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Supported videos directly inside `folder` (not recursive), sorted by name.
    /// Hidden files are skipped.
    public static func videos(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter(isSupportedVideo)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
