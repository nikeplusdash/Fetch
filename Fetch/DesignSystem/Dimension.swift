import Foundation

/// **Four points, with two-point half-steps for hairline-adjacent nudges only.**
///
/// The UI pass was drawn in CSS, where nothing stops a value being 9, 11 or 13,
/// and several were. Every one is snapped here and the mocks are corrected to
/// match, so there is one set of numbers rather than a set in the browser and a
/// set in the app that drift the moment either is edited. See
/// `docs/superpowers/specs/2026-08-13-ui-pass-tokens-and-components.md` §1 for
/// the table of what moved.
public enum Spacing {
    public static let s2: CGFloat = 2,  s4: CGFloat = 4
    public static let s6: CGFloat = 6,  s8: CGFloat = 8
    public static let s10: CGFloat = 10
    public static let s12: CGFloat = 12, s14: CGFloat = 14
    public static let s16: CGFloat = 16
    public static let s20: CGFloat = 20, s24: CGFloat = 24
}

/// The window's own geometry, for the two columns that have to reckon with it.
///
/// The title bar is hidden, which hands the content every point of the window
/// including the strip the traffic lights sit in. Both columns have to leave
/// room for them and they have to leave the *same* room, or the first nav item
/// and the search field beside it sit at two different heights across the
/// divider — which is the seam a merged title bar exists to remove.
///
/// **Here rather than in `FetchApp`.** Three plans are built in parallel and
/// two of them add seams to that file; the numbers all three read must not sit
/// where any of them is editing.
public enum WindowMetrics {
    /// Clearance for the traffic lights: they occupy roughly 9–22pt down the
    /// window, and this leaves a clear band beneath them before anything else
    /// starts. Their own position is AppKit's and is not ours to move — the
    /// job here is only to keep out of their way.
    public static let titleBarInset: CGFloat = 32
    public static let sidebarWidth: CGFloat = 200
    /// How far the traffic lights sit from the window's left and top edges,
    /// and the left edge the sidebar's rows share with them.
    ///
    /// **AppKit's number, and the rows come to meet it.** This is where macOS
    /// places the buttons in a hidden-title-bar window — measured off the
    /// running app — not a choice of ours. It used to be 12, held there by a
    /// `TrafficLightAligner` that nudged the buttons and re-applied the nudge
    /// whenever the title bar undid it; but the title bar undoes it on every
    /// re-layout, including ones no notification announces (switching
    /// sections is one), so the buttons visibly hopped between the two
    /// positions. Only one of the two ends of that hop is stable, and it is
    /// AppKit's. The sidebar pads by this same number, so the rows still
    /// share the buttons' left edge and nothing needs to move anything.
    public static let trafficLightInset: CGFloat = 9
    /// The run the three buttons occupy, and how tall one is — both measured
    /// off the running window. The app's name in the sidebar clears the first
    /// and rides on the centre line implied by the second.
    public static let trafficLightsWidth: CGFloat = 60
    public static let trafficLightDiameter: CGFloat = 14
    /// The lights' centre line, down from the top of the window.
    public static var trafficLightsCenterY: CGFloat {
        trafficLightInset + trafficLightDiameter / 2
    }

    /// The primary pill row's own trim: how far it is lifted into the gap the
    /// title strip leaves, and how much is left clear beneath it before the
    /// rule.
    ///
    /// **One pair, because two screens tuned separately drifted.** Downloads
    /// and Settings each carried their own numbers and ended up 2pt apart —
    /// invisible on either screen alone, and plain the moment you switch
    /// between them. Worse, both pairs summed to the same total, so the rule
    /// under the row landed identically on both and only the pills disagreed,
    /// which reads as a rendering fault rather than as a spacing choice.
    public static let pillBarLift: CGFloat = 8
    public static let pillBarGap: CGFloat = 10

    /// The gap between the app-name strip and the first control beneath it.
    ///
    /// **One rule, four places.** Every column's first thing is: the strip,
    /// this gap, then a control `barHeight` tall. The sidebar's first
    /// destination, Search's field, the Downloads filters and the Settings
    /// panes all centre on the same line because they are all that sum. They
    /// were three different sums before, agreeing in pairs and never all at
    /// once — moving one to match another just moved which pair was wrong.
    public static let firstControlGap: CGFloat = 8

    /// The row holding whatever this screen's primary control is — the search
    /// field, the download filters, the settings panes. One per screen.
    ///
    /// Equal to `RowHeight.searchField` on purpose: the field *is* one of
    /// these, so a second number for the others could only ever drift from it.
    public static let barHeight: CGFloat = 36
    /// The second row, on the one screen that has one: the Library's category
    /// pills. Equal to `RowHeight.searchField` so a bar holding a field and a
    /// bar holding pills are the same height.
    public static let subBarHeight: CGFloat = 36
    /// The line across the bottom that never moves.
    public static let railHeight: CGFloat = 28

    /// One sidebar destination.
    ///
    /// **Stated, not left to padding.** The row used to be whatever 10 points
    /// above and below a line of text came to, and its distance from the top of
    /// the window was that plus a strip plus a stack's spacing — three numbers
    /// that had to agree with the detail column's single `barHeight` and had
    /// nothing making them. The first row now centres in a `barHeight` band of
    /// its own, so the first destination and the first control of whatever
    /// screen it opens sit on one line by construction.
    public static let sidebarRowHeight: CGFloat = 36

    /// The horizontal inset of every row, column head, bar and settings group.
    ///
    /// **One number, and `sheetInset` is the only other.** A third is a bug:
    /// the whole reason the results header used to sit outside its own columns
    /// was two insets that nobody had written down.
    public static let contentInset: CGFloat = 20
    /// The same, inside a sheet, which is narrower and cannot spare 20.
    public static let sheetInset: CGFloat = 16

    /// Padding *inside* a field or a card — not the band it sits in.
    ///
    /// **The distinction is why the left edges disagreed.** Search wrote
    /// `Spacing.s12` for both: the padding inside the search field's rounded
    /// rect, and the padding that positions that rect in the column. The first
    /// is the box's own business and 12 is right for it; the second is the
    /// column's left edge, which every row beneath it sets at 20. So the field
    /// and the pills started eight points left of the results under them, and
    /// nothing in the code said the two numbers were meant to be different
    /// things, because they were the same number spelled the same way.
    public static let controlInset: CGFloat = 12
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
    /// The search field. **Fixed, not derived from padding.** While a search
    /// runs the field also holds a count and a progress bar, and the bar is
    /// taller than a line of text — so a padded field grew the moment you
    /// pressed Return and shrank again when the last indexer answered.
    public static let searchField: CGFloat = 36

    /// Vertical padding inside a list row, both halves.
    ///
    /// **Six, measured against the results list.** A Search row comes to about
    /// 36 points; a Downloads row was coming to 47, because its tallest
    /// element is the 24-point status glyph rather than the 18-point line of
    /// text, and ten points either side of a 24-point glyph is a different row
    /// height from ten either side of a word. Six brings the two lists to the
    /// same rhythm without touching the glyph.
    public static let rowPaddingV: CGFloat = 6
    /// The same, for a file inside an expanded download.
    ///
    /// **Smaller than a top-level row, but not by as much as it was.** These
    /// were at 2, which is what the child block looked like in the mock and not
    /// what it looks like with real filenames in it: six files of a torrent ran
    /// together into one paragraph of text with a checkbox down the side. A
    /// child row is subordinate to its parent, which is what the indent and the
    /// rule say; it does not also need to be cramped to prove it.
    public static let fileRowPaddingV: CGFloat = 6
    /// Between every pair of columns, in every grid in the app.
    ///
    /// Sixteen, not twelve: Size, Seeds and Source ran together as one block of
    /// right-aligned figures, and a gap that separates columns has to be wider
    /// than the spaces inside them.
    public static let columnGap: CGFloat = 16
    /// A row's name to its sub-line.
    public static let subLineGap: CGFloat = 2
    /// A row's sub-line to its progress track.
    public static let trackTopGap: CGFloat = 6
    public static let trackHeight: CGFloat = 3
}

/// The seeder cell: four bars, a gap, and up to five digits.
///
/// **Here so that the column cannot be narrower than its contents.** The bars
/// and the digits were sized in `SeederMeterView` and the column that holds
/// them in `ColumnWidth`, in another file, with nothing tying the two together
/// — so narrowing the column to 42 left a 59-point pair overflowing seventeen
/// points into the Size column and drawing on top of it. A `.frame` does not
/// clip, so the failure is silent and looks like a rendering bug rather than an
/// arithmetic one.
public enum SeederMeter {
    /// Four two-point bars with a point between them.
    public static let barsWidth: CGFloat = 4 * 2 + 3
    /// Five digits of `calloutMono`. Twice revised by measurement: 30 wrapped
    /// "2195", 34 truncated "32700", and popular releases sort to the top so
    /// the wrong one was always the first row on screen.
    public static let countWidth: CGFloat = 44
    public static let width: CGFloat = barsWidth + Spacing.s4 + countWidth
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
    ///
    /// **The only one now.** The list is `.plain`, so nothing else insets the
    /// rows, and the header outside the list applies this very same modifier —
    /// which is what finally makes the two line up rather than nearly.
    ///
    /// **The same number as `WindowMetrics.contentInset`, and now literally
    /// it.** They were two constants holding 20 in two files, which is how the
    /// search field came to sit at 12 while the rows under it sat at 20 and
    /// nothing in the code looked wrong.
    public static let rowInset: CGFloat = WindowMetrics.contentInset
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
    ///
    /// **Seventy-six, because "1,018.9 MB" wrapped.** A four-figure megabyte
    /// count with a grouping separator is the widest thing this column holds
    /// and it did not fit in 62, so the row grew to two lines to say a size.
    public static let size: CGFloat = 76
    /// A file's size inside the downloads tree, e.g. "998.4 MB".
    public static let fileSize: CGFloat = 68
    /// Seeders: a four-bar meter, a gap, and up to four digits.
    ///
    /// Left-aligned in the row rather than centred, so the *bars* line up
    /// down the column. Centring the pair meant a two-digit count pushed its
    /// meter left of a one-digit count's, and a column of meters at four
    /// different offsets does not read as a column at all.
    ///
    /// **Derived, not chosen.** It is exactly what the meter and its digits
    /// need; anything smaller does not truncate, it overlaps the column to its
    /// left. To make this column narrower, narrow `SeederMeter.countWidth`.
    public static let count: CGFloat = SeederMeter.width
    /// The indexer or source name a result came from. Truncates rather than
    /// reserving room for the longest name anyone could configure — it is the
    /// least load-bearing column on the row, and the title is the most.
    public static let source: CGFloat = 64

    /// A download's state glyph, with no word beside it.
    ///
    /// `state` above is 92, sized for "Cancelled", and a list of nine downloads
    /// spent all of it repeating eight strings. The word survives as the
    /// glyph's tooltip and accessibility label; these 68 points become the
    /// `added` column and the rest goes to the title.
    public static let status: CGFloat = 24
    /// A download's total size, e.g. "12.6 GB". Narrower than `byteCount`,
    /// which holds a transferred-of-total pair.
    public static let downloadSize: CGFloat = 64
    /// When a download started: "14:02", "Yesterday", "2 Mar".
    ///
    /// It is the sort key, so it is on the screen. A list claiming to be
    /// newest-first with no date on it is asking to be trusted.
    public static let added: CGFloat = 96
}
