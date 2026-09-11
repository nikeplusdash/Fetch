import Testing
import Foundation
@testable import FetchKit

@Suite struct LogRedactionTests {

    @Test func aNameBecomesAStandInThatDoesNotContainIt() {
        let token = LogRedaction.token("Some Very Identifying Title 2024")
        #expect(!token.lowercased().contains("identifying"))
        #expect(!token.lowercased().contains("title"))
    }

    @Test func theSameNameAlwaysGivesTheSameStandIn() {
        #expect(LogRedaction.token("a.mkv") == LogRedaction.token("a.mkv"))
        #expect(LogRedaction.token("a.mkv") != LogRedaction.token("b.mkv"))
    }


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


    @Test func credentialsAreScrubbedOutOfMessages() {
        let scrubbed = LogRedaction.scrub("failed: apikey=abcd1234 token: zzz9")
        #expect(!scrubbed.contains("abcd1234"))
        #expect(!scrubbed.contains("zzz9"))
    }

    @Test func aBareSecretWithNoKeywordIsNotRedactable() {
        let scrubbed = LogRedaction.scrub("failed for user sk-live-abc")
        #expect(scrubbed.contains("sk-live-abc"), "documented limit, not an oversight")
    }

    @Test func ordinaryTextIsLeftAlone() {
        let message = "download finished in 3 attempts, 2 files"
        #expect(LogRedaction.scrub(message) == message)
    }
}

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

    @Test func credentialsNeverReachTheFile() async {
        let log = FetchLog(directory: temporaryDirectory())
        await log.write(.info, "debrid", "sent apikey=SUPERSECRET")

        #expect(!(await log.contents()).contains("SUPERSECRET"))
    }

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
