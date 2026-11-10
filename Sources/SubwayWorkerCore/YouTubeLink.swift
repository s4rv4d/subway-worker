import Foundation

/// A YouTube video reference parsed from whatever the user pasted.
///
/// Accepts `watch?v=`, `youtu.be/`, `/shorts/`, `/embed/`, `/live/`, `/v/` links on
/// youtube.com / m. / music. / youtube-nocookie.com, with or without a scheme, plus
/// bare 11-character video IDs. Picks up `t=` / `start=` timestamps like `90`, `90s`
/// or `1h2m3s`.
public struct YouTubeLink: Codable, Equatable, Hashable, Sendable {
    public var videoID: String
    /// Shorts are vertical (9:16); everything else is assumed 16:9.
    public var isShort: Bool
    public var startSeconds: Int?

    public init(videoID: String, isShort: Bool = false, startSeconds: Int? = nil) {
        self.videoID = videoID
        self.isShort = isShort
        self.startSeconds = startSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case videoID, isShort, startSeconds
    }

    /// Decoding re-validates the ID: it ends up in the embed page, so a tampered preference
    /// must not be able to smuggle markup or script in through it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .videoID)
        guard Self.isValidID(id) else {
            throw DecodingError.dataCorruptedError(forKey: .videoID, in: container, debugDescription: "Not a YouTube video ID")
        }
        videoID = id
        isShort = try container.decodeIfPresent(Bool.self, forKey: .isShort) ?? false
        startSeconds = try container.decodeIfPresent(Int.self, forKey: .startSeconds).flatMap { $0 >= 0 ? $0 : nil }
    }

    public init?(string raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if Self.isValidID(text) {
            self.init(videoID: text)
            return
        }

        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased()
        else { return nil }

        let query = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }
        let pathParts = components.path.split(separator: "/").map(String.init)

        var id: String?
        var isShort = false

        let youtubeHosts: Set<String> = [
            "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
            "youtube-nocookie.com", "www.youtube-nocookie.com",
        ]

        if host == "youtu.be" || host == "www.youtu.be" {
            id = pathParts.first
        } else if youtubeHosts.contains(host) {
            if pathParts.first == "watch" {
                id = queryValue("v")
            } else if pathParts.count >= 2, ["shorts", "embed", "live", "v"].contains(pathParts[0]) {
                id = pathParts[1]
                isShort = pathParts[0] == "shorts"
            }
        } else {
            return nil
        }

        guard let id, Self.isValidID(id) else { return nil }

        // `t` can also live in the fragment on some share links (#t=30).
        var timeText = queryValue("t") ?? queryValue("start")
        if timeText == nil, let fragment = components.fragment, fragment.hasPrefix("t=") {
            timeText = String(fragment.dropFirst(2))
        }
        self.init(videoID: id, isShort: isShort, startSeconds: timeText.flatMap(Self.parseTimestamp))
    }

    public var watchURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        if isShort {
            components.path = "/shorts/\(videoID)"
        } else {
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        }
        return components.url!
    }

    /// Width / height of the video as YouTube serves it.
    public var assumedAspectRatio: Double { isShort ? 9.0 / 16.0 : 16.0 / 9.0 }

    public static func isValidID(_ candidate: String) -> Bool {
        candidate.count == 11 && candidate.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_")
        }
    }

    /// `"90"`, `"90s"`, `"1m30s"`, `"1h2m3s"` → seconds.
    static func parseTimestamp(_ text: String) -> Int? {
        if let plain = Int(text) { return plain >= 0 ? plain : nil }
        var total = 0
        var digits = ""
        var sawUnit = false
        for char in text.lowercased() {
            if char.isNumber {
                digits.append(char)
            } else {
                guard let value = Int(digits) else { return nil }
                let unit: Int
                switch char {
                case "h": unit = 3600
                case "m": unit = 60
                case "s": unit = 1
                default: return nil
                }
                // Pasted links are untrusted: absurd values must not trap on overflow.
                let (seconds, overflowed) = value.multipliedReportingOverflow(by: unit)
                let (sum, sumOverflowed) = total.addingReportingOverflow(seconds)
                guard !overflowed, !sumOverflowed else { return nil }
                total = sum
                digits = ""
                sawUnit = true
            }
        }
        guard sawUnit, digits.isEmpty else { return nil }
        return total
    }
}
