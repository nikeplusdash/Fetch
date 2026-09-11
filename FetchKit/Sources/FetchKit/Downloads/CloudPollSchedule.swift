import Foundation
import FetchPluginAPI

/**
 How often each unfinished cloud torrent is asked after, once it stops
 telling us anything new.

 **Backing off, because clearing the row is not allowed.** A torrent the
 service failed outright, or dropped, keeps its `.cloudQueued` row for as
 long as the app runs, and `CloudPromotion.outcome` must keep it that way:
 TorBox's `mylist` is cache-served, so "absent" is evidence of nothing, and a
 poll that deleted rows on a bad answer is how someone's library starts
 losing entries. The cost of that rule is one request every thirty seconds,
 per dead torrent, forever. Growing the interval bounds the traffic without
 touching the rule — it changes *how often* the question is asked, never
 *whether* the row survives the answer.

 **Never dropped, only slowed.** There is no state in this type that stops a
 torrent being polled: the interval is capped at ten minutes, so the slowest
 a torrent can ever be asked after is six times an hour, and a torrent that
 has been silent since Tuesday is still asked after on Wednesday. A service
 that comes back to life is picked up within one interval.

 **In memory only.** It holds no user data and no decision, only the cadence
 of a loop that starts fresh with the app — the same reasoning that keeps
 preparations unpersisted. A relaunch asks every unfinished torrent once
 immediately, which is the behaviour the app already has.
 */
public struct CloudPollSchedule: Sendable {
    /**
     The floor, and the pump's own tick: a torrent that just changed state is
     asked after again in thirty seconds, which is
     `CloudPromotion.pollInterval`.
     */
    public static let base: Duration = CloudPromotion.pollInterval

    /**
     The ceiling. Ten minutes is six requests an hour for a torrent that has
     stopped saying anything, against 120 today, and is still short enough
     that a service coming back is noticed inside one cup of coffee.
     */
    public static let ceiling: Duration = .seconds(600)

    /**
     The gap after `n` consecutive answers that said nothing new.

     Doubling from thirty seconds: 30, 60, 120, 240, 480, then the ceiling.
     Nine requests in the first hour instead of 120, and the first four
     answers still arrive inside four minutes, so a torrent the service is
     genuinely working through is not slowed while anyone is watching it.

     The exponent is clamped before it is shifted: this takes a count that
     grows for as long as the app runs, and `1 << 64` is a trap, not a long
     interval.
     */
    public static func interval(afterUnchangedAnswers n: Int) -> Duration {
        let steps = min(max(n, 0), 8)
        return min(base * (1 << steps), ceiling)
    }

    private struct Entry: Equatable {
        /**
         The last state the service actually stated. Untouched by a failed
         ask, on purpose.
         */
        var lastState: DebridTorrentState?
        /**
         Consecutive answers that told us nothing new, including the ones
         that were not answers at all.
         */
        var unchangedAnswers: Int
        var nextDue: ContinuousClock.Instant
    }

    private var entries: [DebridTorrentID: Entry] = [:]

    public init() {}

    /**
     Whether this torrent is asked about on this pass.

     A torrent never seen before is always due, so a row the user just added
     is asked about immediately — and so is one that came back after
     `retain(only:)` forgot it.
     */
    public func isDue(_ id: DebridTorrentID, now: ContinuousClock.Instant = .now) -> Bool {
        guard let entry = entries[id] else { return true }
        return now >= entry.nextDue
    }

    /**
     The ones to ask about, in the caller's order, which is
     `CloudPromotion.torrentsToPoll`'s order: the row the user just added
     first.
     */
    public func due(
        from ids: [DebridTorrentID], now: ContinuousClock.Instant = .now
    ) -> [DebridTorrentID] {
        ids.filter { isDue($0, now: now) }
    }

    /**
     What one ask produced, which decides when the next one happens.

     - Parameter answer: the torrent the service returned, or `nil` when the
       lookup threw or the row could not be routed.

     **A different `DebridTorrentState` resets the interval to thirty
     seconds.** State is the signal that something is happening; progress is
     not, deliberately — a torrent can inch along at 3% an hour and still be
     worth asking after only every ten minutes, and a state that changes is
     the moment when the *next* answer is likely to be the interesting one.

     **A `nil` answer backs off rather than resetting.** A service having a
     bad minute is precisely the one that should be asked less often, not
     more; and it leaves the last known state untouched, so when the service
     returns saying what it said before, the interval keeps growing instead
     of restarting from thirty seconds.
     */
    public mutating func record(
        _ id: DebridTorrentID, answer: DebridTorrent?, now: ContinuousClock.Instant = .now
    ) {
        var entry = entries[id] ?? Entry(lastState: nil, unchangedAnswers: 0, nextDue: now)
        if let state = answer?.state, state != entry.lastState {
            entry.lastState = state
            entry.unchangedAnswers = 0
        } else {
            entry.unchangedAnswers += 1
        }
        entry.nextDue = now.advanced(
            by: Self.interval(afterUnchangedAnswers: entry.unchangedAnswers))
        entries[id] = entry
    }

    /**
     Drops everything not in `ids`. **Housekeeping, not a policy**: a torrent
     forgotten here is polled *sooner* (it becomes due immediately), never
     later, so nothing in this type can retire a row. The pump calls it with
     the torrents that still have `.cloudQueued` rows, so promoted and
     removed ones stop costing a dictionary entry.
     */
    public mutating func retain(only ids: Set<DebridTorrentID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
