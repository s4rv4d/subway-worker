import Foundation
import Testing
@testable import SubwayWorkerCore

struct YouTubeLinkTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=2",
        "https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abcdef",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1",
        "https://www.youtube.com/live/dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
        "  dQw4w9WgXcQ  ",
    ])
    func parsesCommonForms(input: String) throws {
        let link = try #require(YouTubeLink(string: input))
        #expect(link.videoID == "dQw4w9WgXcQ")
        #expect(!link.isShort)
    }

    @Test func parsesShorts() throws {
        let link = try #require(YouTubeLink(string: "https://www.youtube.com/shorts/abcDEF12_-x?feature=share"))
        #expect(link.videoID == "abcDEF12_-x")
        #expect(link.isShort)
        #expect(link.assumedAspectRatio < 1)
        #expect(link.watchURL.absoluteString == "https://www.youtube.com/shorts/abcDEF12_-x")
    }

    @Test(arguments: [
        ("https://youtu.be/dQw4w9WgXcQ?t=90", 90),
        ("https://youtu.be/dQw4w9WgXcQ?t=90s", 90),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s", 90),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s", 3723),
        ("https://www.youtube.com/embed/dQw4w9WgXcQ?start=42", 42),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ#t=15", 15),
    ])
    func parsesTimestamps(input: String, seconds: Int) throws {
        let link = try #require(YouTubeLink(string: input))
        #expect(link.startSeconds == seconds)
    }

    @Test(arguments: [
        "",
        "not a link",
        "https://vimeo.com/123456",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/@somechannel",
        "https://www.youtube.com/playlist?list=PL123",
        "https://evil.example/watch?v=dQw4w9WgXcQ",
        "dQw4w9WgXc!",
    ])
    func rejectsGarbage(input: String) {
        #expect(YouTubeLink(string: input) == nil)
    }

    @Test(arguments: [
        "https://youtu.be/dQw4w9WgXcQ?t=abc",
        "https://youtu.be/dQw4w9WgXcQ?t=3000000000000000h",          // overflows ×3600
        "https://youtu.be/dQw4w9WgXcQ?t=9223372036854775807s1s",     // overflows the sum
        "https://youtu.be/dQw4w9WgXcQ?t=99999999999999999999999",    // too big for Int
        "https://youtu.be/dQw4w9WgXcQ?t=-5",
    ])
    func badTimestampIsIgnoredNotFatal(input: String) throws {
        let link = try #require(YouTubeLink(string: input))
        #expect(link.videoID == "dQw4w9WgXcQ")
        #expect(link.startSeconds == nil)
    }
}

struct ClipSourceTests {
    @Test func roundTripsThroughJSON() throws {
        let sources: [ClipSource] = [
            .file(URL(fileURLWithPath: "/Users/me/Movies/run.mp4")),
            .folder(URL(fileURLWithPath: "/Users/me/Movies/brainrot", isDirectory: true)),
            .youtube(YouTubeLink(videoID: "dQw4w9WgXcQ", isShort: true, startSeconds: 12)),
            .template(.ringBounce),
        ]
        let data = try JSONEncoder().encode(sources)
        #expect(try JSONDecoder().decode([ClipSource].self, from: data) == sources)
    }

    @Test func folderListingFiltersAndSorts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["clip10.mp4", "clip2.MOV", "notes.txt", ".hidden.mp4", "clip1.m4v", "clip.webm"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        let names = VideoLibrary.videos(in: dir).map(\.lastPathComponent)
        #expect(names == ["clip1.m4v", "clip2.MOV", "clip10.mp4"])
    }
}
