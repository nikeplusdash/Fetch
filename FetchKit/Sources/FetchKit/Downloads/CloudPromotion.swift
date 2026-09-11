import Foundation
import FetchPluginAPI

/**
 When a `.cloudQueued` row becomes an `.onCloud` one.

 **Asked about by id, never by listing the account.** TorBox's `mylist` is
 served from a cache that lags: measured live on 2026-08-15, a torrent added
 seconds earlier was absent from it while `mylist?id=<id>` returned the same
 torrent complete. A promotion driven by a listing would therefore stall
 forever on exactly the torrents the user is watching — the new ones — and a
 listing read as authoritative about absence would clear their rows outright.
 Per-id lookup was measured accurate immediately after submit, so that is
 what the poll uses. The same lagging cache is why a full account listing can
 never be trusted about the torrents it leaves out.

 **This poll is not the launch-time reconcile the cloud-rows design forbids.**
 That rule is about re-verifying rows already known to be ready: a round trip
 in front of every launch, answered from a cache that can only make things
 worse. These rows are known to be *incomplete*. They are the ones where an
 answer can only be new information, and nothing here can ever clear a row —
 the only move it makes is forward.
 */
public enum CloudPromotion {
    /**
     How often each incomplete row asks after itself.

     Thirty seconds: short enough that a torrent the service already had
     lands in the Library while the user is still looking at the row, long
     enough that a torrent the service takes an hour over costs 120 requests
     instead of 3600.
     */
    public static let pollInterval: Duration = .seconds(30)

    /**
     The file id a whole-torrent placeholder carries.

     A row needs a file, and a torrent the service has not fetched has no
     file list to take one from — so the placeholder speaks for the torrent
     and says so in its id. The unit separator is there because no service
     mints one: the id is the dedup key that pairs a placeholder with the
     real file rows that later replace it, and a placeholder that collided
     with a real file id would suppress the row for that file forever.
     */
    public static let placeholderFileID = DebridFileID(rawValue: "\u{1F}whole-torrent")

    public static func isPlaceholder(_ fileID: DebridFileID) -> Bool {
        fileID == placeholderFileID
    }

    /**
     The stand-in row for a torrent the service has accepted and not yet
     fetched. Named and sized from the torrent, which is all `DebridTorrent`
     carries before it is ready — and all a row needs.
     */
    public static func placeholderFile(name: String, size: Int64) -> DebridFile {
        DebridFile(
            id: placeholderFileID, name: name, shortName: name,
            size: size, mimeType: nil)
    }

    public enum Outcome: Sendable, Equatable {
        /**
         Leave the placeholder exactly where the user has been watching it.
         */
        case keepWaiting
        /**
         The service has these files now. Replace the placeholder with one
         row per file, in the same group.
         */
        case promote([DebridFile])
    }

    /**
     What one answer about one torrent means for its placeholder row.

     `nil` — the lookup threw, or the row's provider is gone — is
     `keepWaiting`, deliberately. A network blip, an expired key and a
     service having a bad minute all arrive here as nothing, and none of
     them is a statement that the torrent has gone. **This function has no
     case that clears a row**, which is the property that makes running it
     on a timer safe.

     Readiness is `DebridTorrent.isReady`: state *or* `filesArePresent`, and
     a non-empty file list either way. TorBox calls a finished torrent
     `uploading` the moment it starts seeding, so a poll keyed on the word
     alone would wait for a transition that has already happened; and a
     service that says "ready" while listing nothing has no rows to write,
     so promoting it would delete the placeholder and put nothing in its
     place.

     `placeholderStillPresent` is the second half of the question, and it is
     asked **after** the round trip rather than before it. A poll is a
     network call long, which is long enough for the user to remove the row
     it is about; promoting on the strength of the list the pass started
     with wrote a full set of `.onCloud` rows for a torrent that had just
     been taken off the screen — and under a freshly minted
     `DownloadGroupKey`, so what came back was not even the row they
     removed. False here means the row has gone, and a row that has gone
     gets no answer.
     */
    public static func outcome(
        for torrent: DebridTorrent?, placeholderStillPresent: Bool = true
    ) -> Outcome {
        guard placeholderStillPresent else { return .keepWaiting }
        guard let torrent, torrent.isReady else { return .keepWaiting }
        return .promote(torrent.files)
    }

    /**
     Why the service says it cannot fetch this torrent, in the row's words.

     **A second reading of the same answer, not a third `Outcome` case.**
     `outcome` has no case that clears a row and must not grow one: a poll
     answer is not evidence of absence, and a listing read as authoritative
     about absence is how rows start disappearing. A *failed* state is
     different in kind — it is the service volunteering that it has stopped —
     and the honest use of it is to say so on the row and let the user
     decide. So this returns a sentence and nothing else happens: the row
     stays, the poll continues (more slowly, on a backed-off schedule), and
     removal remains a person's decision.

     `nil` for a torrent that is fine, and for `nil` itself — a lookup that
     threw says nothing about the torrent.

     The four named reasons are the ones the providers actually mint:
     `magnet_error`, `virus`, `dead` (`RealDebridProvider`) and `timeout`
     (`PremiumizeProvider`). TorBox maps its failures to the bare words
     `failed`/`error` (`DebridDTOs`), which carry no information, so they get
     the plain sentence rather than a colon and a repeat of the word "error".

     The `default` branch handles somebody else's string, so it is capped
     before it is shown: the sub-line truncates in the row anyway, and an
     unbounded provider message is the one thing here that could outrun the
     microcopy rule about sentence length. A hundred characters is what that
     rule leaves once the fifty-character opening is spent.
     */
    public static func diagnosis(for torrent: DebridTorrent?) -> String? {
        guard case .failed(let raw)? = torrent?.state else { return nil }
        let detail = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        switch detail.lowercased() {
        case "virus": return "Your debrid service found a virus in this torrent."
        case "dead": return "Nobody is seeding this torrent, so your service could not fetch it."
        case "magnet_error": return "Your debrid service could not read the magnet link."
        case "timeout": return "Your debrid service gave up waiting for this torrent."
        case "", "failed", "error": return couldNotFetch + "."
        default:
            let short = detail.count > 100 ? String(detail.prefix(100)) + "…" : detail
            return couldNotFetch + ": " + short
        }
    }

    /**
     Spelled once so the two endings of the same sentence cannot drift.
     */
    private static let couldNotFetch = "Your debrid service could not fetch this torrent"

    /**
     Which torrents this pass asks about: the incomplete ones, each once.

     **Deduplicated by torrent id** so a placeholder that has already been
     half-promoted, or a torrent that somehow holds two rows, costs one
     request rather than one per row — the same one-request-per-torrent
     argument that recovery fan-out makes. Order is the caller's, so the
     row the user just added is asked about first.
     */
    public static func torrentsToPoll(
        rows: [(torrentID: DebridTorrentID, state: DownloadState)]
    ) -> [DebridTorrentID] {
        var seen: Set<DebridTorrentID> = []
        var ordered: [DebridTorrentID] = []
        for row in rows where row.state == .cloudQueued {
            if seen.insert(row.torrentID).inserted { ordered.append(row.torrentID) }
        }
        return ordered
    }
}
