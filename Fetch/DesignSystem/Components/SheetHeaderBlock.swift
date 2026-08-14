import SwiftUI

/// The block at the top of a sheet holding everything true about the item.
///
/// **One container, because they are one thought.** The four sheets each grew
/// their own header, and the facts about an item ended up scattered to the
/// corners: the size and source under the name, "via TorBox" in its own row at
/// the foot level with Cancel and Download as though it were an action, the
/// destination as a bare grey `/Users/…` line above the buttons, and whether the
/// service had to fetch it first as a full amber sentence *below* the buttons —
/// the far corner of the sheet from the thing it described.
///
/// They are all one kind of statement: this is what you are about to download.
/// So they are one block, and the buttons underneath are left holding only
/// actions.
struct SheetHeaderBlock<Facts: View>: View {
    let title: String
    /// The Queued / Ready pill, or nil while the availability answer is still
    /// out. **Nil rather than a greyed placeholder**: a pill that was there all
    /// along, waiting, is a promise the sheet cannot keep, because the answer
    /// comes back from the network after the sheet is already open.
    var tag: TagPill?
    /// Size, source, `via <service>`, and the destination. Supplied by the
    /// sheet because a book has different facts from a torrent, and separated
    /// by `SheetFactSeparator`.
    @ViewBuilder var facts: Facts

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s6) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(title)
                    .font(FetchFont.sheetTitle)
                    // **One line, truncating.** It used to be three, wrapping,
                    // on the argument that this is the one place with room to
                    // say the whole name. It is not: three lines of a release
                    // name push the pill onto its own line and take the top
                    // third of the sheet before a single file is listed. The
                    // whole name is still selectable and still in the tooltip.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let tag {
                    tag
                        // It arrives late, so it should look like it arrives.
                        // The availability answer is genuinely new information
                        // appearing on an open sheet.
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }

            HStack(spacing: Spacing.s8) {
                facts
            }
            .font(FetchFont.callout)
            .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WindowMetrics.sheetInset)
        .padding(.vertical, Spacing.s14)
        .animation(.snappy(duration: 0.34), value: tag?.title)
    }
}

/// A hairline between two bands of a sheet.
///
/// **Not `Divider()`.** The stock divider draws AppKit's separator colour and
/// ignores `Palette.separator` entirely, so a theme cannot touch it: Midnight
/// deliberately thins its separators to compensate for a near-black pane, and
/// every `Divider()` in the app threw that away and drew the system's line at
/// the system's weight. One rule, reading the token, so a theme reaches all of
/// them.
///
/// The interpunct between two facts.
///
/// A component rather than a `Text("·")` at each call site, because the four
/// sheets each spelled their own separator into an interpolated string — which
/// is how one of them ended up with " — " and how a nil fact left a stranded
/// dot with nothing after it.
struct SheetFactSeparator: View {
    var body: some View {
        Text(verbatim: "·")
            .foregroundStyle(Palette.textTertiary)
            .accessibilityHidden(true)
    }
}
