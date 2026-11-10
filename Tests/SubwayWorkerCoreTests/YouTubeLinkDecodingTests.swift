import Foundation
import Testing
@testable import SubwayWorkerCore

struct YouTubeLinkDecodingTests {
    @Test(arguments: [
        #"{"videoID":"</script><script>alert(1)</script>","isShort":false}"#,
        #"{"videoID":"short","isShort":false}"#,
        #"{"videoID":"dQw4w9WgXc!","isShort":false}"#,
    ])
    func rejectsTamperedIDs(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(YouTubeLink.self, from: Data(json.utf8))
        }
    }

    @Test func dropsNegativeStartTimes() throws {
        let json = #"{"videoID":"dQw4w9WgXcQ","isShort":true,"startSeconds":-30}"#
        let link = try JSONDecoder().decode(YouTubeLink.self, from: Data(json.utf8))
        #expect(link == YouTubeLink(videoID: "dQw4w9WgXcQ", isShort: true, startSeconds: nil))
    }
}
