import Foundation

/// One row, one state.
///
/// A row is a torrent and a torrent is several files, so the glyph at the head
/// of it has to answer for all of them with one symbol. `DownloadGrouping`
/// already reduces the same states to a *section*; this reduces them to the
/// state that section is named after, which is what the glyph and the filter
/// both need. Two reductions of one truth is a thing that drifts, so this one
/// is written to agree with `DownloadGrouping.section` case for case, and a
/// test asserts they still do.
///
/// **Movement outranks failure.** A torrent still transferring reads
/// downloading even when one of its files has already failed — the alternative
/// is a row that flips to a warning triangle mid-transfer and back again when
/// the next file lands.
public enum DownloadRowState {
    /// Nil for no files at all, which is not a state — it is a row that should
    /// not be drawn.
    public static func of(_ states: [DownloadState]) -> DownloadState? {
        guard !states.isEmpty else { return nil }

        // In order, and the order is the argument. Everything above `.queued`
        // is in flight; everything below it has stopped, and among the stopped
        // the ones needing attention outrank the ones that are simply done —
        // a row where nine files landed and one did not is a row with a
        // problem, and saying "Completed" would hide it.
        if states.contains(.downloading) { return .downloading }
        if states.contains(.preparing) { return .preparing }
        if states.contains(.paused) { return .paused }
        if states.contains(.queued) { return .queued }
        if states.contains(.failed) { return .failed }
        if states.contains(.missing) { return .missing }
        if states.contains(.cancelled) { return .cancelled }
        return .completed
    }
}
