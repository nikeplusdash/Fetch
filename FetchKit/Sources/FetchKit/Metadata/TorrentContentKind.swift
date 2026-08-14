import Foundation
import FetchPluginAPI

/// What a torrent is, judged by what is actually in it.
///
/// **A dropped torrent has no indexer to ask.** A search result arrives with a
/// Torznab category and `TorznabKind` reads it; a `.torrent` dragged onto the
/// window has only its name, and the name is exactly the signal that has been
/// getting this wrong — a year made an album a film, and made three Adobe
/// releases films too. But a dropped torrent has something a search result does
/// not: its complete file list, parsed locally by `TorrentFile`. Ninety FLACs
/// is an album whatever the folder is called.
///
/// The name is still consulted, second, and only for the two things a file list
/// cannot say: whether a video is an episode or a film, and whether an
/// executable is a game or an application.
public enum TorrentContentKind {
    /// What one file is, as far as deciding the whole torrent goes.
    public enum FileClass: String, Sendable, CaseIterable {
        case video, audio, book, software
        /// Subtitles, artwork, checksums, release notes. **Excluded from the
        /// count rather than counted as unknown**, which is the difference
        /// between a film and a mystery: a scene release routinely carries more
        /// `.srt` and `.nfo` files than video files, and a bare majority vote
        /// over everything would call it neither.
        case accessory
        case unknown
    }

    /// The bank. Extensions only — a name is not consulted here, so a file
    /// called `Movie.2020.mkv` and one called `a.mkv` count the same.
    static let classes: [FileClass: Set<String>] = [
        .video: [
            "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg",
            "mpeg", "m2ts", "ts", "vob", "3gp", "ogv", "m2v", "divx", "rmvb",
        ],
        .audio: [
            "mp3", "flac", "m4a", "aac", "opus", "ogg", "wav", "wma", "aiff",
            "ape", "wv", "dsf", "dff", "alac", "mka",
            // An audiobook container, and the one extension that decides the
            // whole torrent on its own. See `kind(files:name:)`.
            "m4b",
        ],
        .book: [
            "epub", "mobi", "azw", "azw3", "cbz", "cbr", "djvu", "fb2", "lit",
            "pdf", "chm",
        ],
        .software: ["exe", "msi", "dmg", "pkg", "deb", "rpm", "apk", "app", "arc"],
        .accessory: [
            // Subtitles and their indexes.
            "srt", "sub", "idx", "ssa", "ass", "vtt", "sup",
            // Artwork, which a music release has one of per disc and a film
            // release has a folder of.
            "jpg", "jpeg", "png", "gif", "bmp", "webp",
            // Release notes, checksums, links, and the torrent itself.
            "nfo", "sfv", "md5", "sha1", "txt", "url", "torrent", "diz", "m3u",
            "cue", "log", "json", "xml", "db", "sqlite", "ini",
        ],
    ]

    public static func fileClass(of name: String) -> FileClass {
        fileClass(of: name, hasCueSheet: false)
    }

    /// `.bin` is the ambiguous one and it matters, because it is most of a game
    /// repack by file count — Elden Ring's is four `.bin` archives and a
    /// `setup.exe`, which without this reads as 75% unknown and decides
    /// nothing. It is also half of a `.cue`/`.bin` disc image, which is music.
    /// The cue sheet is what tells them apart, so it is passed in rather than
    /// guessed at.
    static func fileClass(of name: String, hasCueSheet: Bool) -> FileClass {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .unknown }
        if ext == "bin" { return hasCueSheet ? .audio : .software }
        for (kind, extensions) in classes where extensions.contains(ext) { return kind }
        return .unknown
    }

    /// The share each class holds of the files that count.
    ///
    /// Accessories are removed first. What is left is the question "what is
    /// this torrent *for*", and a folder of cover art is not an answer.
    public static func composition(of files: [String]) -> [FileClass: Double] {
        let hasCue = files.contains {
            ($0 as NSString).pathExtension.lowercased() == "cue"
        }
        let counted = files
            .map { fileClass(of: $0, hasCueSheet: hasCue) }
            .filter { $0 != .accessory }
        guard !counted.isEmpty else { return [:] }
        var tally: [FileClass: Int] = [:]
        for item in counted { tally[item, default: 0] += 1 }
        return tally.mapValues { Double($0) / Double(counted.count) }
    }

    /// A simple majority of the files that count. Below this the file list is
    /// not making a claim and the name is left to it.
    public static let majority = 0.5

    /// What the torrent is, or nil when its contents do not say.
    ///
    /// `name` refines rather than decides: a video majority is a video either
    /// way, and the name only chooses between film and episode. An `.m4b` is
    /// the one extension that crosses a class boundary on its own — it is an
    /// audiobook container, so a torrent of them is a book however much audio
    /// it is.
    public static func kind(files: [String], name: String? = nil) -> MediaKind? {
        guard !files.isEmpty else { return nil }

        // Checked before the tally: one .m4b among a hundred .mp3s is still an
        // audiobook release, and the majority would call it music.
        if files.contains(where: { ($0 as NSString).pathExtension.lowercased() == "m4b" }) {
            return .book
        }

        let shares = composition(of: files)
        guard let (winner, share) = shares.max(by: { $0.value < $1.value }),
              share >= majority, winner != .unknown
        else { return nil }

        let parsed = name.map(ReleaseNameParser.parse)

        switch winner {
        case .video:
            // The one thing a file list cannot tell you about video. Anime is
            // the parser's call for the same reason.
            if let parsed, parsed.season != nil || !parsed.episodes.isEmpty {
                return parsed.mediaKind == .anime ? .anime : .tv
            }
            return .movie
        case .audio:
            return .music
        case .book:
            return .book
        case .software:
            // An executable is an application or a game and the files look
            // identical; the name is the only thing that distinguishes them.
            if let parsed, parsed.mediaKind == .game { return .game }
            return .software
        case .accessory, .unknown:
            return nil
        }
    }
}
