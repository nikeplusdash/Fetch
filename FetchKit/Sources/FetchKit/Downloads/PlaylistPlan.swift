import Foundation

/**
 Where one item of a playlist's bytes are.
 */
public enum PlaylistSource: Sendable, Equatable {
    /**
     On this Mac. Handed to the player as a file URL, resolving nothing —
     and, unlike a link from the service, it cannot fail on the way.
     */
    case local(URL)

    /**
     Only on the service. `token` is whatever the screen that built this can
     resolve a credentialed URL from — a `DownloadID` on Downloads. Opaque
     here on purpose: this file has no business knowing it, and a playlist is
     the same list of decisions whichever screen asked for one.
     */
    case cloud(token: String)
}

/**
 One file a playlist *could* hold, before anything is filtered or ordered.
 */
public struct PlaylistCandidate: Sendable, Equatable {
    /**
     The file's path inside the torrent. **The ordering key**, and the only
     thing that carries the torrent's own structure — a row's display name is
     the last component and is not unique across a season pack's folders.
     */
    public let path: String

    /**
     Nil when the bytes are nowhere yet: a queued file, a failed one, or a
     torrent the service has accepted and not fetched.
     */
    public let source: PlaylistSource?

    public init(path: String, source: PlaylistSource?) {
        self.path = path
        self.source = source
    }
}

/**
 One file that is actually going into the playlist.
 */
public struct PlaylistItem: Sendable, Equatable, Identifiable {
    public let path: String
    public let source: PlaylistSource

    public var id: String { path }

    public var isLocal: Bool {
        if case .local = source { return true }
        return false
    }

    /**
     The name this file will be known by — the one on disk when it is here,
     because that is the name a player shows and §9 renames on the way down.
     */
    public var displayName: String { PlaylistPlan.displayName(path: path, source: source) }
}

/**
 What a **whole folder or torrent** offers, and what happens when only some
 of it can be reached.

 **The playlist is the reason this is a type and not a loop in a menu.** Three
 separate decisions live here, each of them a combination, and the app target
 has no test bundle to assert any of them in: which files are eligible and in
 what order, which players can be handed the result at all, and what a
 half-resolved playlist plays.
 */
public enum PlaylistPlan {

    /**
     The eligible files, in the torrent's own order.

     **Order is taken from the paths, never from the order the candidates
     arrive in.** The rows a screen holds are in library order, account-listing
     order, or whatever a re-download left behind; the paths are the torrent's.
     A season played in the wrong order is worse than no playlist, which is
     the entire reason for the sort.

     Playability is asked of `displayName`, which is the on-disk name for a
     local file — the same rule, for the same reason, as the one a row's own
     Play answers to: §9 renames files on the way down, and the name a player
     is handed is the one it landed under.
     */
    public static func items(from candidates: [PlaylistCandidate]) -> [PlaylistItem] {
        candidates
            .compactMap { candidate -> PlaylistItem? in
                guard let source = candidate.source else { return nil }
                let item = PlaylistItem(path: candidate.path, source: source)
                guard ExternalPlayer.canPlay(fileNamed: item.displayName) else { return nil }
                return item
            }
            .sorted { precedes($0.path, $1.path) }
    }

    /**
     The name this file will be known by — the one on disk when it is here,
     because that is the name a player shows and §9 renames on the way down.
     One rule, asked by an item (which has a source) and by a candidate
     (which may not).
     */
    static func displayName(path: String, source: PlaylistSource?) -> String {
        if case .local(let url) = source { return url.lastPathComponent }
        return (path as NSString).lastPathComponent
    }

    /**
     How many media files this list covers, reachable or not — the
     denominator behind "Play 9 of 12".

     **Media only, and that is the whole decision.** A release is a video
     plus the things around it, and counting `release.nfo`, `sample.rar` and
     `poster.jpg` would report "Play 2 of 7" for a clean two-episode
     torrent — a shortfall that does not exist, on the commonest torrent
     layout there is. What the number has to be honest about is the opposite
     case: episodes the torrent holds whose bytes are nowhere, which are
     candidates with no source and used to be invisible (issue #5).
     */
    public static func mediaCount(in candidates: [PlaylistCandidate]) -> Int {
        candidates.count {
            ExternalPlayer.canPlay(
                fileNamed: displayName(path: $0.path, source: $0.source))
        }
    }

    /**
     "Play All (9)" when the list is everything, "Play 9 of 12" when it is
     not. `>=` rather than `==` so a bad denominator can never read
     "Play 9 of 8"; it degrades to the honest half of the pair.
     */
    public static func title(count: Int, total: Int) -> String {
        count >= total ? "Play All (\(count))" : "Play \(count) of \(total)"
    }

    /**
     Path order, component by component.

     Two rules, and both are `FileTree`'s — the tree the picker sheet outlines
     with — so a playlist plays in the order the user has already been shown
     the files in:

     1. **Numbers compare as numbers** (`localizedStandardCompare`), so `ep2`
        comes before `ep10` rather than after `ep1`.
     2. **A folder comes before a file beside it**, so a season pack finishes
        a season before it reaches the loose extras at the torrent's root.

     More path below a component is what makes that component a folder.
     */
    static func precedes(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: "/", omittingEmptySubsequences: true)
        let right = b.split(separator: "/", omittingEmptySubsequences: true)
        for index in 0..<min(left.count, right.count) where left[index] != right[index] {
            let leftIsFolder = left.count > index + 1
            let rightIsFolder = right.count > index + 1
            if leftIsFolder != rightIsFolder { return leftIsFolder }
            return String(left[index]).localizedStandardCompare(String(right[index]))
                == .orderedAscending
        }
        return left.count < right.count
    }

    /**
     The candidates that live inside one folder of the torrent, however deep.

     **The separator is load-bearing.** `hasPrefix("Show/Season 1")` puts
     every episode of season 10 inside season 1, and "Season 1 Extras" with
     them — the same mistake this project has already made three times by
     comparing a path as a string instead of as somewhere a file lands.
     */
    public static func candidates(
        _ candidates: [PlaylistCandidate], under folder: String
    ) -> [PlaylistCandidate] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return candidates.filter { $0.path.hasPrefix(prefix) }
    }

    /**
     A playlist worth offering, and the players that can actually take it.
     */
    public struct Offer: Sendable, Equatable {
        public let items: [PlaylistItem]

        /**
         The installed players that accept this playlist, in the order the
         system reported them.
         */
        public let players: [ExternalPlayer]

        /**
         The user's default player — **only when it is one of them**. Quietly
         substituting another player would open an app the setting does not
         name, which is the one thing `DefaultPlayer` exists to prevent.
         */
        public let defaultPlayer: ExternalPlayer?

        /**
         Every media file this offer covers, reachable or not. `count` is
         what will actually play; this is what the user was looking at.
         */
        public let total: Int

        public var count: Int { items.count }

        /**
         The words in the menu.

         **The menu is where the shortfall has to be visible.** A playlist
         that says "Play All (9)" over a twelve-episode torrent is a claim
         the user only finds out about at the gap, an hour in.
         */
        public var title: String { PlaylistPlan.title(count: count, total: total) }

        /**
         Whether every item is a file on this Mac, which is what decides
         whether IINA can be one of the players.
         */
        public var isAllLocal: Bool { items.allSatisfy(\.isLocal) }
    }

    /**
     What this folder or torrent should put in a menu, or nil for nothing.

     Nil in two cases, and neither is a failure: fewer than two playable files
     (one file is a Play, and the menu already has one), or no installed
     player that can take a list of this shape.
     */
    public static func offer(
        candidates: [PlaylistCandidate], defaultPlayer: ExternalPlayer?,
        installed: [ExternalPlayer]
    ) -> Offer? {
        let items = items(from: candidates)
        guard items.count > 1 else { return nil }
        let allLocal = items.allSatisfy(\.isLocal)
        let players = installed.filter { $0.acceptsPlaylist(allLocalFiles: allLocal) }
        guard !players.isEmpty else { return nil }
        return Offer(
            items: items, players: players,
            defaultPlayer: defaultPlayer.flatMap { players.contains($0) ? $0 : nil },
            total: mediaCount(in: candidates))
    }

    /**
     What a playlist actually became once every cloud link had been asked for.
     */
    public struct Resolution: Sendable, Equatable {
        /**
         In playlist order, with the unreachable items closed up rather than
         left as gaps — a player handed a bad URL stops on it.
         */
        public let urls: [URL]

        /**
         The names that did not resolve, in playlist order.
         */
        public let missing: [String]

        /**
         Nil when nothing went wrong. A banner on a success is how a banner
         becomes something people dismiss without reading.
         */
        public let notice: String?

        /**
         Whether to launch a player at all. Launching one on an empty
         playlist is a window that opens and does nothing.
         */
        public var opens: Bool { !urls.isEmpty }
    }

    /**
     The playlist to hand over, given what each cloud token resolved to.

     **A partial playlist plays.** Withholding nineteen episodes because the
     twentieth link expired is the worse of the two failures, and the one the
     user can do nothing about; the ones that did not come are named, so a
     jump from episode 2 to episode 4 is an explained gap rather than a
     mystery. When *nothing* resolved there is no playlist to play, and the
     notice says that instead.

     - Parameter resolved: cloud token → URL, absent for every token whose
       lookup failed. Local items are not in it and do not need to be.
     */
    public static func resolution(
        for items: [PlaylistItem], resolved: [String: URL]
    ) -> Resolution {
        var urls: [URL] = []
        var missing: [String] = []
        for item in items {
            switch item.source {
            case .local(let url):
                urls.append(url)
            case .cloud(let token):
                if let url = resolved[token] { urls.append(url) } else { missing.append(item.displayName) }
            }
        }
        return Resolution(urls: urls, missing: missing, notice: notice(
            played: urls.count, total: items.count, missing: missing))
    }

    private static func notice(played: Int, total: Int, missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        guard played > 0 else {
            return "None of the \(total) files could be played. Your service returned "
                + "no link for any of them — it may be busy, or the torrent may be gone."
        }
        return "Playing \(played) of \(total). \(list(missing)) could not be reached, "
            + "so \(missing.count == 1 ? "it was" : "they were") left out."
    }

    /**
     Three names and a count. A dozen filenames in a banner is a paragraph
     nobody reads, and the count is the part that says how bad it was.
     */
    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(3).map { "“\($0)”" }
        let rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) others" }
        if shown.count == 1 { return shown[0] }
        return shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
    }
}
