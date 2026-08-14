import Foundation

/// Everything a row's one sub-line could be built from.
///
/// A struct rather than nine arguments, because the call site is a view and a
/// view passing nine positional values is a view making decisions about their
/// order.
public struct DownloadRowFacts: Sendable {
    public var state: DownloadState
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    /// Chosen once from the total, so "998 MB of 1.0 GB" never becomes
    /// "1.0 GB of 1.0 GB" a tick later. See `ByteCount.pinnedUnit(for:)`.
    public var pinnedUnit: ByteCountFormatter.Units
    public var etaText: String?
    /// The sentence a failed download left behind.
    public var failureReason: String?
    /// The folder a finished download landed in, relative to the download
    /// root — `Movies/Nosferatu (1922)`, not `/Users/…/Movies/…`.
    public var destination: String?
    /// Where a queued row sits in the line, 1-based. Nil when the position is
    /// not knowable, which is not the same as first.
    public var queuePosition: Int?
    /// What the debrid says it is doing, in its own words. Only a preparing
    /// row has one.
    public var preparingStatus: String?

    public init(
        state: DownloadState,
        bytesDownloaded: Int64 = 0,
        totalBytes: Int64 = 0,
        pinnedUnit: ByteCountFormatter.Units = .useAll,
        etaText: String? = nil,
        failureReason: String? = nil,
        destination: String? = nil,
        queuePosition: Int? = nil,
        preparingStatus: String? = nil
    ) {
        self.state = state
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.pinnedUnit = pinnedUnit
        self.etaText = etaText
        self.failureReason = failureReason
        self.destination = destination
        self.queuePosition = queuePosition
        self.preparingStatus = preparingStatus
    }
}

/// The one fact a Downloads row says under its name.
///
/// **One fact, never two.** The row used to carry a joined sentence of up to
/// five parts — file count, bytes, rate, ETA, provider — every one of which
/// changes length as a download runs, so the row reflowed ten times a second
/// and said five things none of which was the one you wanted. The columns now
/// carry size, rate and date; this carries the single thing the columns cannot,
/// and which thing that is depends on the state:
///
/// - running: how far along, and how long is left
/// - queued: where in the line
/// - failed: why, and the way out
/// - finished: nothing. The glyph has already said so, and where it landed is
///   the row's tooltip rather than a line under every entry in the library
///
/// Nil where the state has nothing to add that the row is not already showing.
/// An empty sub-line is better than a filler one: the row keeps its height
/// either way, and a line that always says something teaches people to stop
/// reading it.
public enum DownloadSubline {
    public static func text(_ facts: DownloadRowFacts, locale: Locale = .current) -> String? {
        switch facts.state {
        case .downloading:
            let moved = transferred(facts)
            guard let eta = facts.etaText else { return moved }
            return "\(moved), \(eta) left"

        case .preparing:
            // The service's own words when there are any. "Stalled, waiting
            // for seeds" is the difference between a torrent that is working
            // and one that never will, and a spinner says neither.
            return facts.preparingStatus ?? "Your debrid service is fetching it."

        case .queued:
            guard let position = facts.queuePosition, position > 0 else {
                return "Waiting for a free slot."
            }
            return "\(ordinal(position, locale: locale)) in line"

        case .paused:
            guard let percent = percent(facts) else { return "Paused." }
            return "Paused at \(percent)%"

        case .completed:
            // **Nothing at all.** This was the destination, then the
            // destination unless it repeated the name — which was too clever by
            // half: the organisation rules slugify a release into its folder,
            // so "Dune: Part Three |" landed in
            // "Other/dune-part-three-imax-trailer-1-4k-prores" and the rule saw
            // two different strings where a reader sees one thing said twice.
            //
            // A finished row has already answered the only question it is
            // asked, which is whether it finished, and the glyph answers that.
            // Where it landed is worth having and is not worth a line on every
            // row in the library: it is the row's tooltip, and Show in Finder
            // is one click away in the context menu.
            return nil

        case .failed:
            // The reason is the useful half and the way out is the other; a
            // failed download is resumable, which is exactly what the reader
            // wants to know and what the old bare "Failed" never said.
            guard let reason = facts.failureReason, !reason.isEmpty else {
                return "It did not finish. Try again."
            }
            return "\(sentence(reason)) Try again"

        case .cancelled:
            guard let percent = percent(facts) else { return "You stopped this." }
            return "Stopped at \(percent)%"

        case .missing:
            // Not "Downloaded, but the file is no longer where Fetch saved
            // it." The first half of that sentence is what the row's Completed
            // history already says, and the second half is the whole message.
            return "Not where Fetch saved it."
        }
    }

    /// `3.1 of 4.4 GB`, not `3.1 GB of 4.4 GB`.
    ///
    /// Both figures are pinned to one unit, so naming it twice spends eight
    /// characters of a truncating column saying the same word twice. Dropped
    /// only when the two strings genuinely end in the same unit — a mismatch
    /// means the pinning failed, and then the units are load-bearing.
    static func transferred(_ facts: DownloadRowFacts) -> String {
        let total = ByteCount.format(facts.totalBytes, pinnedTo: facts.pinnedUnit)
        let done = ByteCount.format(facts.bytesDownloaded, pinnedTo: facts.pinnedUnit)
        guard let unit = total.split(separator: " ").last,
              done.hasSuffix(" \(unit)")
        else { return "\(done) of \(total)" }
        return "\(done.dropLast(unit.count + 1)) of \(total)"
    }

    private static func percent(_ facts: DownloadRowFacts) -> Int? {
        guard facts.totalBytes > 0 else { return nil }
        let fraction = Double(facts.bytesDownloaded) / Double(facts.totalBytes)
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// Ends the reason before the next clause starts, so two sentences never
    /// run into each other. A reason that already ends in punctuation keeps it.
    private static func sentence(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private static func ordinal(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

}
