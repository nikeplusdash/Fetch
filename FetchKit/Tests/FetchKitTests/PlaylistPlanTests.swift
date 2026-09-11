import Testing
import Foundation
@testable import FetchKit
import FetchPluginAPI

/**
 What "open everything in here as a playlist" resolves to.

 Three decisions, all of them combinations, none of them assertable from the
 app target: which files are eligible and in what order, which players can be
 handed a whole playlist at all, and what a half-resolved playlist produces.
 */
@Suite struct PlaylistPlanTests {
    /**
     A file on this Mac.
     */
    private func local(_ path: String, at disk: String? = nil) -> PlaylistCandidate {
        PlaylistCandidate(
            path: path,
            source: .local(URL(fileURLWithPath: "/Movies/" + (disk ?? path))))
    }

    /**
     A file only the service has.
     */
    private func cloud(_ path: String, token: String? = nil) -> PlaylistCandidate {
        PlaylistCandidate(path: path, source: .cloud(token: token ?? path))
    }

    /**
     A file whose bytes are nowhere yet — queued, failed, or a torrent the
     service has accepted and not fetched.
     */
    private func nowhere(_ path: String) -> PlaylistCandidate {
        PlaylistCandidate(path: path, source: nil)
    }

    private func paths(_ items: [PlaylistItem]) -> [String] { items.map(\.path) }

    /**
     A release is a video plus the things around it. Handing a player the
     `.nfo` and the sample's `.rar` is how a playlist becomes twenty error
     dialogs.
     */
    @Test func onlyMediaGoesIntoThePlaylist() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/S01E01.mkv"),
            cloud("Show/S01E01.srt"),
            cloud("Show/release.nfo"),
            cloud("Show/poster.jpg"),
            cloud("Show/sample.rar"),
            cloud("Show/S01E02.mp4"),
            cloud("Show/theme.flac"),
        ])
        #expect(paths(items) == ["Show/S01E01.mkv", "Show/S01E02.mp4", "Show/theme.flac"])
    }

    /**
     Playability is asked of the name **on disk** when there is one: §9
     renames files on the way down, and the name a player is handed is the one
     it landed under.
     */
    @Test func aRenamedFileIsJudgedByItsNameOnDisk() {
        let items = PlaylistPlan.items(from: [
            local("payload.bin", at: "Ronin (1998).mkv"),
        ])
        #expect(paths(items) == ["payload.bin"])
    }

    /**
     A queued file, a failed one, a torrent the service has accepted and not
     fetched — no bytes anywhere, so nothing to put in a playlist.
     */
    @Test func aFileWhoseBytesAreNowhereIsLeftOut() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/S01E01.mkv"), nowhere("Show/S01E02.mkv"),
        ])
        #expect(paths(items) == ["Show/S01E01.mkv"])
    }

    @Test func aFolderWithNothingPlayableInItIsEmpty() {
        let items = PlaylistPlan.items(from: [
            cloud("Docs/manual.pdf"), cloud("Docs/cover.png"), cloud("Docs/notes.txt"),
        ])
        #expect(items.isEmpty)
    }

    /**
     **Order comes from the torrent, not from the rows.** The rows arrive in
     whatever order the library, the account listing or a re-download left
     them in; the paths are the torrent's own.
     */
    @Test func orderComesFromThePathAndNotFromTheInputOrder() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/S01E03.mkv"), cloud("Show/S01E01.mkv"), cloud("Show/S01E02.mkv"),
        ])
        #expect(paths(items) == ["Show/S01E01.mkv", "Show/S01E02.mkv", "Show/S01E03.mkv"])
    }

    /**
     Plain string order puts `ep10` second. An episode list in that order is
     worse than no playlist at all, which is the reason this function exists.
     */
    @Test func numbersSortAsNumbers() {
        let items = PlaylistPlan.items(from: [
            cloud("ep10.mkv"), cloud("ep2.mkv"), cloud("ep1.mkv"), cloud("ep20.mkv"),
        ])
        #expect(paths(items) == ["ep1.mkv", "ep2.mkv", "ep10.mkv", "ep20.mkv"])
    }

    /**
     A season pack is nested, and each season has to finish before the next
     one starts.
     */
    @Test func nestedSeasonFoldersPlayOneSeasonAtATime() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/Season 2/S02E01.mkv"),
            cloud("Show/Season 10/S10E01.mkv"),
            cloud("Show/Season 1/S01E02.mkv"),
            cloud("Show/Season 1/S01E01.mkv"),
        ])
        #expect(paths(items) == [
            "Show/Season 1/S01E01.mkv", "Show/Season 1/S01E02.mkv",
            "Show/Season 2/S02E01.mkv", "Show/Season 10/S10E01.mkv",
        ])
    }

    /**
     `FileTree`'s rule, so the playlist plays in the order the screen already
     lists the files: a folder before a file beside it.
     */
    @Test func aFolderComesBeforeALooseFileNextToIt() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/bonus.mkv"), cloud("Show/Extras/interview.mkv"),
        ])
        #expect(paths(items) == ["Show/Extras/interview.mkv", "Show/bonus.mkv"])
    }

    /**
     **The mixed group is the normal case.** Half a season downloaded and
     half still on the service is one playlist in torrent order, not a local
     playlist followed by a cloud one.
     */
    @Test func localAndCloudFilesInterleaveInTorrentOrder() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/S01E04.mkv"),
            local("Show/S01E01.mkv"),
            cloud("Show/S01E02.mkv"),
            local("Show/S01E03.mkv"),
        ])
        #expect(paths(items) == [
            "Show/S01E01.mkv", "Show/S01E02.mkv", "Show/S01E03.mkv", "Show/S01E04.mkv",
        ])
        #expect(items.map(\.isLocal) == [true, false, true, false])
    }

    /**
     Right-clicking a folder plays that folder, not the torrent around it.
     */
    @Test func aFolderTakesOnlyWhatIsInsideIt() {
        let all = [
            cloud("Show/Season 1/S01E01.mkv"),
            cloud("Show/Season 2/S02E01.mkv"),
            cloud("Show/bonus.mkv"),
        ]
        let inside = PlaylistPlan.candidates(all, under: "Show/Season 1")
        #expect(inside.map(\.path) == ["Show/Season 1/S01E01.mkv"])
    }

    /**
     **The separator is part of the test, not a detail.** A plain prefix
     match puts every episode of season 10 inside season 1, which is the
     third time in this project that a path was compared as a string rather
     than as somewhere a file lands.
     */
    @Test func aFolderDoesNotSwallowTheFolderNamedAfterIt() {
        let all = [
            cloud("Show/Season 1/S01E01.mkv"),
            cloud("Show/Season 10/S10E01.mkv"),
            cloud("Show/Season 1 Extras/deleted.mkv"),
        ]
        #expect(PlaylistPlan.candidates(all, under: "Show/Season 1").map(\.path)
            == ["Show/Season 1/S01E01.mkv"])
    }

    /**
     Everything below it, however deep — a folder is what it contains.
     */
    @Test func aFolderReachesItsSubfoldersToo() {
        let all = [
            cloud("Show/Season 1/E01.mkv"),
            cloud("Show/Season 1/Featurettes/making-of.mkv"),
            cloud("Show/other.mkv"),
        ]
        #expect(PlaylistPlan.candidates(all, under: "Show").count == 3)
        #expect(PlaylistPlan.candidates(all, under: "Show/Season 1").count == 2)
    }

    @Test func vlcAndMpvTakeAPlaylistWhereverTheBytesAre() {
        for player in [ExternalPlayer.vlc, .mpv] {
            #expect(player.acceptsPlaylist(allLocalFiles: true))
            #expect(player.acceptsPlaylist(allLocalFiles: false))
        }
    }

    /**
     QuickTime opens a window per file. Twenty windows is not a playlist, so
     the action is not offered for it rather than offered and disappointing.
     */
    @Test func quickTimeNeverTakesAPlaylist() {
        #expect(!ExternalPlayer.quickTime.acceptsPlaylist(allLocalFiles: true))
        #expect(!ExternalPlayer.quickTime.acceptsPlaylist(allLocalFiles: false))
    }

    /**
     IINA takes any number of files handed to it by Launch Services — but a
     remote URL reaches it through `iina://weblink`, which carries exactly
     one. So a playlist with anything on the service in it cannot go to IINA.
     */
    @Test func iinaTakesAPlaylistOnlyWhenEveryItemIsOnThisMac() {
        #expect(ExternalPlayer.iina.acceptsPlaylist(allLocalFiles: true))
        #expect(!ExternalPlayer.iina.acceptsPlaylist(allLocalFiles: false))
    }

    /**
     The default that cannot take a mixed list is no default at all: silently
     using another player would be a different app opening than the one the
     setting names.
     */
    @Test func aLocalPlaylistIsOfferedToIINAAndAMixedOneIsNot() {
        let installed: [ExternalPlayer] = [.iina, .vlc, .mpv, .quickTime]
        let allLocal = PlaylistPlan.offer(
            candidates: [local("a.mkv"), local("b.mkv")],
            defaultPlayer: .iina, installed: installed)
        #expect(allLocal?.players == [.iina, .vlc, .mpv])
        #expect(allLocal?.defaultPlayer == .iina)
        #expect(allLocal?.isAllLocal == true)

        let mixed = PlaylistPlan.offer(
            candidates: [local("a.mkv"), cloud("b.mkv")],
            defaultPlayer: .iina, installed: installed)
        #expect(mixed?.players == [.vlc, .mpv])
        #expect(mixed?.defaultPlayer == nil)
    }

    /**
     One file is a Play, and the menu already has one.
     */
    @Test func oneEligibleFileIsNotAPlaylist() {
        #expect(PlaylistPlan.offer(
            candidates: [local("a.mkv"), cloud("notes.txt")],
            defaultPlayer: .vlc, installed: [.vlc]) == nil)
    }

    @Test func nothingIsOfferedWhenNoInstalledPlayerTakesAPlaylist() {
        #expect(PlaylistPlan.offer(
            candidates: [cloud("a.mkv"), cloud("b.mkv")],
            defaultPlayer: .quickTime, installed: [.quickTime]) == nil)
        #expect(PlaylistPlan.offer(
            candidates: [cloud("a.mkv"), cloud("b.mkv")],
            defaultPlayer: nil, installed: []) == nil)
    }

    /**
     The submenu lists players in the order the system reported them, minus
     the ones that cannot take this playlist.
     */
    @Test func theOfferKeepsTheInstalledOrder() {
        let offer = PlaylistPlan.offer(
            candidates: [cloud("a.mkv"), cloud("b.mkv")],
            defaultPlayer: .mpv, installed: [.mpv, .vlc])
        #expect(offer?.players == [.mpv, .vlc])
        #expect(offer?.count == 2)
    }

    @Test func aWholePlaylistIsPlayAll() {
        #expect(PlaylistPlan.title(count: 9, total: 9) == "Play All (9)")
    }

    /**
     **The menu is where the shortfall has to be visible.** "Play All (9)"
     over a twelve-episode torrent is a claim the user only finds out about
     at the gap, an hour in.
     */
    @Test func aShortPlaylistSaysHowShort() {
        #expect(PlaylistPlan.title(count: 9, total: 12) == "Play 9 of 12")
    }

    /**
     **The denominator is media, and that is the whole decision.** A release
     is a video plus the things around it; counting the `.nfo`, the sample
     and the poster would report "Play 2 of 5" for a clean two-episode
     torrent — a shortfall that does not exist.
     */
    @Test func theExtrasOfAReleaseAreNotADenominator() {
        let offer = PlaylistPlan.offer(
            candidates: [
                cloud("Show/S01E01.mkv"), cloud("Show/S01E02.mkv"),
                cloud("Show/release.nfo"), cloud("Show/sample.rar"),
                cloud("Show/poster.jpg"),
            ],
            defaultPlayer: .vlc, installed: [.vlc])
        #expect(offer?.total == 2)
        #expect(offer?.title == "Play All (2)")
    }

    /**
     **The #5 regression test.** Episodes the torrent holds whose bytes are
     nowhere used to be invisible: the menu counted what would play and said
     nothing about what would not.
     */
    @Test func aFileWithNoBytesAnywhereStillCounts() {
        let offer = PlaylistPlan.offer(
            candidates: [
                cloud("Show/S01E01.mkv"), cloud("Show/S01E02.mkv"),
                nowhere("Show/S01E03.mkv"),
            ],
            defaultPlayer: .vlc, installed: [.vlc])
        #expect(offer?.count == 2)
        #expect(offer?.total == 3)
        #expect(offer?.title == "Play 2 of 3")
    }

    /**
     The numerator and the denominator ask the same name — the one on disk,
     because §9 renames files on the way down.
     */
    @Test func aRenamedLocalFileIsCountedByItsNameOnDisk() {
        let offer = PlaylistPlan.offer(
            candidates: [local("payload.bin", at: "Ronin (1998).mkv"), local("b.mkv")],
            defaultPlayer: .vlc, installed: [.vlc])
        #expect(offer?.total == 2)
        #expect(offer?.title == "Play All (2)")
    }

    /**
     **A partial playlist plays.** Nineteen files the user asked for, held
     back because the twentieth link expired, is the worse of the two
     failures — and the one the user cannot do anything about.
     */
    @Test func aPartialPlaylistPlaysAndNamesWhatIsMissing() {
        let items = PlaylistPlan.items(from: [
            cloud("Show/S01E01.mkv"), cloud("Show/S01E02.mkv"), cloud("Show/S01E03.mkv"),
        ])
        let resolution = PlaylistPlan.resolution(
            for: items,
            resolved: [
                "Show/S01E01.mkv": URL(string: "https://cdn.example/1")!,
                "Show/S01E03.mkv": URL(string: "https://cdn.example/3")!,
            ])
        #expect(resolution.opens)
        #expect(resolution.urls.map(\.absoluteString)
            == ["https://cdn.example/1", "https://cdn.example/3"])
        #expect(resolution.missing == ["S01E02.mkv"])
        #expect(resolution.notice?.contains("2 of 3") == true)
        #expect(resolution.notice?.contains("S01E02.mkv") == true)
    }

    /**
     Everything worked, so the user is told nothing. A notice on a success is
     how a banner becomes something people dismiss without reading.
     */
    @Test func aWholePlaylistSaysNothing() {
        let items = PlaylistPlan.items(from: [cloud("a.mkv"), cloud("b.mkv")])
        let resolution = PlaylistPlan.resolution(
            for: items,
            resolved: [
                "a.mkv": URL(string: "https://cdn.example/a")!,
                "b.mkv": URL(string: "https://cdn.example/b")!,
            ])
        #expect(resolution.urls.count == 2)
        #expect(resolution.missing.isEmpty)
        #expect(resolution.notice == nil)
    }

    /**
     A file on this Mac has nothing to resolve, and must not be dropped
     because a lookup table that only concerns the service does not name it.
     */
    @Test func localItemsNeedNoResolutionAndKeepTheirPlace() {
        let items = PlaylistPlan.items(from: [
            local("Show/S01E01.mkv"), cloud("Show/S01E02.mkv"), local("Show/S01E03.mkv"),
        ])
        let resolution = PlaylistPlan.resolution(for: items, resolved: [:])
        #expect(resolution.urls.map(\.lastPathComponent) == ["S01E01.mkv", "S01E03.mkv"])
        #expect(resolution.missing == ["S01E02.mkv"])
        #expect(resolution.opens)
    }

    /**
     A playlist of files that are all on this Mac resolves to exactly those
     files, in playlist order, and needs nothing looked up — which is every
     playlist the Downloads screen builds.
     */
    @Test func anAllLocalPlaylistResolvesToItselfInOrder() {
        let items = PlaylistPlan.items(from: [
            local("Show/S01E02.mkv"), local("Show/S01E01.mkv"),
        ])
        let resolution = PlaylistPlan.resolution(for: items, resolved: [:])
        #expect(resolution.urls.map(\.lastPathComponent) == ["S01E01.mkv", "S01E02.mkv"])
        #expect(resolution.missing.isEmpty)
        #expect(resolution.notice == nil)
        #expect(resolution.opens)
    }

    /**
     Nothing resolved: no player is launched, because launching one on an
     empty playlist is a window that opens and does nothing.
     */
    @Test func nothingResolvedOpensNothingAndSaysSo() {
        let items = PlaylistPlan.items(from: [cloud("a.mkv"), cloud("b.mkv")])
        let resolution = PlaylistPlan.resolution(for: items, resolved: [:])
        #expect(resolution.urls.isEmpty)
        #expect(!resolution.opens)
        #expect(resolution.missing == ["a.mkv", "b.mkv"])
        #expect(resolution.notice?.contains("None of the 2") == true)
    }

    /**
     A dozen names in a banner is a paragraph nobody reads.
     */
    @Test func aLongListOfMissingFilesIsSummarised() {
        let items = PlaylistPlan.items(from: (1...9).map { cloud("ep\($0).mkv") })
        let resolution = PlaylistPlan.resolution(
            for: items, resolved: ["ep1.mkv": URL(string: "https://cdn.example/1")!])
        #expect(resolution.missing.count == 8)
        let notice = resolution.notice ?? ""
        #expect(notice.contains("ep2.mkv"))
        #expect(notice.contains("5 others"))
        #expect(!notice.contains("ep9.mkv"))
    }
}
