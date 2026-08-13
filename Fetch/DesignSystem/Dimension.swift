import Foundation

public enum Spacing {
    public static let s2: CGFloat = 2,  s4: CGFloat = 4
    public static let s6: CGFloat = 6,  s8: CGFloat = 8
    public static let s12: CGFloat = 12, s16: CGFloat = 16
    public static let s20: CGFloat = 20, s24: CGFloat = 24
}

public enum Radius {
    public static let r4: CGFloat = 4,  r6: CGFloat = 6
    public static let r8: CGFloat = 8,  r10: CGFloat = 10
    public static let r12: CGFloat = 12, r16: CGFloat = 16
}

public enum RowHeight {
    public static let compact: CGFloat = 24    // file tree
    public static let regular: CGFloat = 28    // results
    public static let download: CGFloat = 56
}

public enum IconSize {
    public static let xs: CGFloat = 10, sm: CGFloat = 12, md: CGFloat = 14
    public static let lg: CGFloat = 16, xl: CGFloat = 20
}

/// Fixed widths for `DownloadRow`'s numeric columns (byte count, rate,
/// ETA). Even with the value strings themselves stable (mono digits, pinned
/// units, smoothed rate), an unconstrained `Text` still reflows its
/// siblings whenever the string's *length* changes — e.g. "45 sec" versus
/// "about 3 minutes", or the transferred figure gaining a digit. Reserving
/// each column's width up front, sized for the longest realistic string
/// (`ByteCountFormatter`/`DateComponentsFormatter` output at this font),
/// keeps the row static while only the digits inside it change.
public enum ColumnWidth {
    /// How far the results list's rows *and* its header sit from the window
    /// edge.
    ///
    /// One number because they have to be the same number. `List` applies its
    /// own horizontal inset to rows, and the header — a plain `HStack` above
    /// the list — did not get it: every heading sat outside its column, the
    /// left ones appearing shifted right and the right ones shifted left, by
    /// the width of an inset nobody had written down. The rows now state
    /// their inset explicitly and the header reads the same constant.
    public static let rowInset: CGFloat = 14
    /// The results list's two leading columns, reserved whether or not the
    /// row has anything to put in them.
    ///
    /// They were intrinsic, and both are conditional — the cache badge only
    /// appears for a result with an infohash, so a book's title started
    /// tens of points to the left of the torrent above it. A list with a
    /// ragged left edge does not read as columns, and columns are the point
    /// of a sortable header.
    public static let cache: CGFloat = 32
    public static let kind: CGFloat = 64
    public static let byteCount: CGFloat = 132   // "998.4 KB / 1.95 GB"
    public static let rate: CGFloat = 80         // "12.4 MB/s"
    public static let eta: CGFloat = 92          // "about 3 minutes"

    /// A download row's leading state word. Sized for "Cancelled" — at 72 it
    /// wrapped, which is the whole reason this enum exists.
    public static let state: CGFloat = 92
    /// A result row's size figure, e.g. "1.95 GB". Narrower than `byteCount`,
    /// which holds a transferred-of-total pair — and trimmed again to the
    /// widest figure it actually holds. Every point these three trailing
    /// columns were carrying spare was a point the title could not have.
    public static let size: CGFloat = 62
    /// A file's size inside the downloads tree, e.g. "998.4 MB".
    public static let fileSize: CGFloat = 68
    /// Seeders: a four-bar meter, a gap, and up to four digits.
    ///
    /// Left-aligned in the row rather than centred, so the *bars* line up
    /// down the column. Centring the pair meant a two-digit count pushed its
    /// meter left of a one-digit count's, and a column of meters at four
    /// different offsets does not read as a column at all.
    public static let count: CGFloat = 48
    /// The indexer or source name a result came from. Truncates rather than
    /// reserving room for the longest name anyone could configure — it is the
    /// least load-bearing column on the row, and the title is the most.
    public static let source: CGFloat = 88
}
