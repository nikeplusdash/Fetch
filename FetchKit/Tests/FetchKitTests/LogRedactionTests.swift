import Testing
import Foundation
@testable import FetchKit

/// A log people are asked to share has to be shareable.
///
/// The interesting half of any download bug is a filename, a URL and an
/// account, and all three are the user. A log naming what they downloaded and
/// carrying a signed CDN link is not a diagnostic, it is a disclosure — and it
/// only takes one person pasting it into an issue tracker.
@Suite struct LogRedactionTests {
    // MARK: - Content

    @Test func aNameBecomesAStandInThatDoesNotContainIt() {
        let token = LogRedaction.token("Some Very Identifying Title 2024")
        #expect(!token.lowercased().contains("identifying"))
        #expect(!token.lowercased().contains("title"))
    }

    /// Stable, so two lines about one file are visibly about one file — which
    /// is most of what reading a log is for.
    @Test func theSameNameAlwaysGivesTheSameStandIn() {
        #expect(LogRedaction.token("a.mkv") == LogRedaction.token("a.mkv"))
        #expect(LogRedaction.token("a.mkv") != LogRedaction.token("b.mkv"))
    }

    // MARK: - URLs

    /// §6: a debrid's download link carries the account's own token. The host
    /// answers "which service", which is all a diagnosis needs.
    @Test func aURLKeepsItsHostAndNothingElse() {
        let url = URL(string: "https://store-42.tb-cdn.st/dl/abc123?token=SECRETVALUE&file=9")!
        let logged = LogRedaction.host(url)

        #expect(logged == "store-42.tb-cdn.st")
        #expect(!logged.contains("SECRETVALUE"))
        #expect(!logged.contains("abc123"))
    }

    @Test func aSearchURLDoesNotLeakTheQuery() {
        let url = URL(string: "https://jackett.local/api?apikey=KEY&q=something+private")!
        #expect(!LogRedaction.host(url).contains("private"))
    }

    // MARK: - Paths

    /// The folder names are the user's library and the filename is the
    /// content. Depth and extension are what a path bug is actually about.
    @Test func aPathKeepsItsShapeAndLosesItsNames() {
        let logged = LogRedaction.path("/Users/someone/Downloads/Private Folder/Episode 1.mkv")

        #expect(logged.contains(".mkv"))
        #expect(!logged.contains("someone"))
        #expect(!logged.contains("Private"))
        #expect(!logged.contains("Episode"))
    }

    @Test func depthSurvivesBecauseAPathBugIsUsuallyOffByOneLevel() {
        #expect(LogRedaction.path("a/b/c/file.txt") != LogRedaction.path("a/file.txt"))
    }

    // MARK: - Free text

    @Test func credentialsAreScrubbedOutOfMessages() {
        let scrubbed = LogRedaction.scrub("failed: apikey=abcd1234 token: zzz9")
        #expect(!scrubbed.contains("abcd1234"))
        #expect(!scrubbed.contains("zzz9"))
    }

    /// Keyword-anchored on purpose, and the limit is stated rather than
    /// pretended away: a bare secret with no adjacent key name is not
    /// redactable by construction. Same boundary `NetworkError.scrub` documents.
    @Test func aBareSecretWithNoKeywordIsNotRedactable() {
        let scrubbed = LogRedaction.scrub("failed for user sk-live-abc")
        #expect(scrubbed.contains("sk-live-abc"), "documented limit, not an oversight")
    }

    @Test func ordinaryTextIsLeftAlone() {
        let message = "download finished in 3 attempts, 2 files"
        #expect(LogRedaction.scrub(message) == message)
    }
}

/// The log file itself.
@Suite struct FetchLogTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func linesAreWrittenAndReadBack() async {
        let log = FetchLog(directory: temporaryDirectory())
        await log.write(.error, "download", "failed after 3 tries")

        let contents = await log.contents()
        #expect(contents.contains("ERROR"))
        #expect(contents.contains("[download]"))
        #expect(contents.contains("failed after 3 tries"))
    }

    /// Scrubbing runs on the way in, so a caller that forgets is still safe
    /// for the one shape that matters most.
    @Test func credentialsNeverReachTheFile() async {
        let log = FetchLog(directory: temporaryDirectory())
        await log.write(.info, "debrid", "sent apikey=SUPERSECRET")

        #expect(!(await log.contents()).contains("SUPERSECRET"))
    }

    /// Truncating from the front rather than deleting: whatever just went
    /// wrong is the part being asked about.
    @Test func rotationKeepsTheNewestLines() async {
        let log = FetchLog(directory: temporaryDirectory())
        for index in 0..<4_000 {
            await log.write(.info, "bulk", String(repeating: "x", count: 600) + " line\(index)")
        }
        let contents = await log.contents()

        #expect(contents.count <= FetchLog.maximumBytes)
        #expect(contents.contains("line3999"), "the newest line must survive")
    }
}
