import Testing
import Foundation
@testable import FetchKit

/**
 Handing a URL to a player is one line per player — and one of them needs its
 own scheme, which is where a percent-encoding mistake would otherwise hide
 in a view nothing can test.
 */
@Suite struct ExternalPlayerTests {

    private let media = URL(string:
        "https://sg1.real-debrid.com/d/ABC123/Some%20Film%202160p.mkv")!

    @Test func mostPlayersJustOpenTheMediaURL() {
        for player in [ExternalPlayer.vlc, .mpv, .quickTime] {
            #expect(player.openTarget(for: media) == media)
        }
    }

    /**
     IINA takes the media URL as a *query parameter*, so every character that
     is legal in a URL and illegal in a query value has to be escaped —
     including the `/` and `:` of the URL itself, and the `%20` already in
     the filename, whose `%` must not be left to mean something else.

     The pre-existing escape has to survive as an escape rather than decaying
     into a literal space or a stray percent.
     */
    @Test func iinaWrapsTheURLInItsOwnScheme() throws {
        let target = try #require(ExternalPlayer.iina.openTarget(for: media))
        #expect(target.scheme == "iina")
        #expect(target.absoluteString.hasPrefix("iina://weblink?url="))
        #expect(!target.absoluteString.contains("https://"))
        #expect(target.absoluteString.contains("%3A%2F%2F"))
        #expect(target.absoluteString.contains("%2520"))
    }

    @Test func theWrappedURLSurvivesTheRoundTrip() throws {
        let target = try #require(ExternalPlayer.iina.openTarget(for: media))
        let components = try #require(
            URLComponents(url: target, resolvingAgainstBaseURL: false))
        let carried = try #require(
            components.queryItems?.first { $0.name == "url" }?.value)
        #expect(carried == media.absoluteString)
    }

    @Test func everyPlayerHasABundleIdentifierToLookUp() {
        for player in ExternalPlayer.allCases {
            #expect(!player.bundleIdentifier.isEmpty)
            #expect(!player.displayName.isEmpty)
        }
    }

    /**
     Streaming is offered for things a player can play, and nothing else — a
     Stream button on a `.rar` is a button that opens a player on an error.
     */
    @Test func onlyPlayableFilesAreWorthStreaming() {
        #expect(ExternalPlayer.canPlay(fileNamed: "Film.mkv"))
        #expect(ExternalPlayer.canPlay(fileNamed: "Album/01 - Track.flac"))
        #expect(ExternalPlayer.canPlay(fileNamed: "SHOW.S01E01.1080p.MP4"))
        #expect(!ExternalPlayer.canPlay(fileNamed: "release.rar"))
        #expect(!ExternalPlayer.canPlay(fileNamed: "book.epub"))
        #expect(!ExternalPlayer.canPlay(fileNamed: "no-extension"))
    }
}
