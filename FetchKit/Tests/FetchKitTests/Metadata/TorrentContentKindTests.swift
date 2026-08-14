import Testing
import Foundation
import FetchPluginAPI
@testable import FetchKit

/// What a dropped torrent is, from its file list.
///
/// A dropped `.torrent` has no indexer category to read, and its name is the
/// signal that has been getting this wrong all along. Its file list is not.
@Suite("Torrent contents")
struct TorrentContentKindTests {
    @Test("Ninety FLACs are an album whatever the folder is called")
    func audioMajorityIsMusic() {
        let files = (1...12).map { "\($0) Track.flac" } + ["cover.jpg", "folder.nfo"]
        #expect(TorrentContentKind.kind(files: files, name: "Something 2019") == .music)
    }

    /// The accessory rule, which is the one that makes the majority mean
    /// anything: a scene release carries more subtitles and notes than video.
    @Test("Subtitles and artwork do not outvote the film")
    func accessoriesAreNotCounted() {
        let files = ["Film.2019.1080p.mkv", "a.srt", "b.srt", "c.srt", "d.srt",
                     "poster.jpg", "film.nfo", "sample.txt"]
        #expect(TorrentContentKind.kind(files: files, name: "Film 2019 1080p") == .movie)
        #expect(TorrentContentKind.composition(of: files)[.video] == 1.0)
    }

    /// The two things a file list cannot say, which is all the name is for.
    @Test("The name chooses between film and episode")
    func nameSeparatesFilmFromEpisode() {
        let episodes = (1...8).map { "Show.S04E0\($0).1080p.mkv" }
        #expect(TorrentContentKind.kind(files: episodes, name: "Show.S04.1080p") == .tv)
        #expect(TorrentContentKind.kind(files: episodes, name: nil) == .movie)
    }

    @Test("The name chooses between an application and a game")
    func nameSeparatesSoftwareFromGame() {
        let files = ["setup.exe", "data.bin", "readme.txt"]
        #expect(TorrentContentKind.kind(files: files, name: "Adobe Photoshop 2024") == .software)
        #expect(TorrentContentKind.kind(
            files: files, name: "ELDEN RING v1.12 FitGirl Repack") == .game)
    }

    /// `.bin` is most of a game repack by file count and half of a music disc
    /// image. The cue sheet is what tells them apart.
    @Test("A cue sheet makes bin audio rather than software")
    func cueSheetDisambiguatesBin() {
        let disc = ["album.cue", "album.bin"]
        #expect(TorrentContentKind.kind(files: disc, name: "Artist - Album") == .music)
        let repack = ["setup.exe", "fg-01.bin", "fg-02.bin"]
        #expect(TorrentContentKind.kind(files: repack, name: "Game Repack") == .software)
    }

    /// One audiobook container settles it: the majority would say music, and a
    /// twelve-hour narration does not belong beside the albums.
    @Test("An m4b is a book however much audio it is")
    func audiobookContainerWins() {
        let files = (1...7).map { "Book\($0).m4b" } + ["cover.jpg"]
        #expect(TorrentContentKind.kind(files: files, name: "Harry Potter") == .book)
    }

    @Test("Books are books")
    func bookMajority() {
        #expect(TorrentContentKind.kind(
            files: ["Dune.epub", "Dune 2.epub", "cover.jpg"], name: "Dune Saga") == .book)
    }

    /// Nil rather than a guess. Nothing in an empty or unrecognised list is a
    /// claim about what the torrent is, and overriding a good name-parse with
    /// nothing is worse than saying nothing.
    @Test("An unrecognised list makes no claim")
    func unknownContentsDefer() {
        #expect(TorrentContentKind.kind(files: [], name: "Whatever") == nil)
        #expect(TorrentContentKind.kind(files: ["a.qqq", "b.zzz"], name: "Whatever") == nil)
        #expect(TorrentContentKind.kind(files: ["only.nfo", "art.jpg"], name: "X") == nil)
    }
}
