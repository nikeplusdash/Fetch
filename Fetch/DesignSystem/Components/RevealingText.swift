import SwiftUI

/// A single line of text that truncates like any other — until the row it sits
/// in is selected, when it slides sideways to show the rest and slides back.
///
/// **Why a component and not a modifier at three call sites.** Three lists show
/// long names in a fixed column (search results, book results, downloads), and
/// all three had exactly one answer for a name that did not fit: middle
/// truncation and a tooltip. A tooltip is a good fallback and a poor primary —
/// it costs a hover, a delay, and knowing it is there at all.
///
/// **It cannot change the row's width.** `ColumnWidth`'s fixed columns exist
/// because an unconstrained `Text` reflows a whole row as its neighbours'
/// numbers change, ten times a second during a download. So the scrolling
/// version is laid out at its intrinsic width *inside* a flexible frame and
/// clipped: the row sees the same flexible box whether or not anything is
/// moving.
///
/// **It degrades to exactly the old behaviour.** If the measurement comes back
/// empty — a text that has not been laid out yet, a platform that lays
/// backgrounds out differently than expected — `overflow` is zero, nothing
/// scrolls, and what renders is the middle-truncated `Text` this replaced.
struct RevealingText: View {
    let text: String
    /// Normally "is this row selected". The reveal is deliberately tied to
    /// selection rather than hover: a pointer crossing a list would set half a
    /// dozen rows moving on its way past, and motion that follows the cursor
    /// reads as the list being unstable rather than as an affordance.
    let isRevealing: Bool
    var font: Font = FetchFont.body

    /// Points per second. Slow enough to read a release name as it passes —
    /// the point is to *read* it, and anything brisk enough to feel responsive
    /// is too fast to follow.
    private static let speed: CGFloat = 22
    /// Held still at the start so the beginning of the name is readable before
    /// anything moves, and at the end so the tail is too.
    private static let dwell: TimeInterval = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - visibleWidth) }

    /// A hair over zero, not over zero: sub-pixel differences between the
    /// measured and laid-out widths would otherwise start a "scroll" of a
    /// fraction of a point, which is a name that twitches.
    private var isScrolling: Bool { isRevealing && overflow > 1 && !reduceMotion }

    /// Constant speed rather than constant duration, so a name twice as long
    /// takes twice as long rather than moving twice as fast.
    private var travel: TimeInterval { max(0.3, TimeInterval(overflow / Self.speed)) }

    var body: some View {
        // **The layout is always the truncating text, even while it scrolls.**
        //
        // This used to swap the whole view for a `KeyframeAnimator` wrapping a
        // `.fixedSize` label, inside `.frame(maxWidth: .infinity)`. That frame
        // proposes a width; it does not cap the *ideal* one, which the fixed
        // label reports as the full untruncated title. In the results list the
        // name column carries `.layoutPriority(1)`, so selecting a row with a
        // long name handed that column everything and squeezed Size, Seeds and
        // Source to nothing — the row appeared to shift left and lose its
        // trailing columns for exactly as long as it was selected.
        //
        // The moving label is an overlay now. An overlay takes part in no
        // layout at all, so the row is laid out identically whether or not
        // anything is moving, which is what the comment below always claimed
        // and what `.frame(maxWidth:)` could not deliver.
        staticLabel
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isScrolling ? 0 : 1)
            .overlay(alignment: .leading) {
                if isScrolling {
                    // **Clipped to a number, not to a frame.** `.clipped()` on
                    // the composite below clips to whatever width this view was
                    // laid out at — and in the results list the name column
                    // carries `.layoutPriority(1)` inside a container that
                    // proposes an unbounded width while measuring, so the clip
                    // rectangle was sometimes the *ideal* width and clipped
                    // nothing at all. The moving label then drew straight over
                    // Size, Seeds and Source: selecting a row made its name
                    // appear to pop out on top of the rest of the table.
                    //
                    // `visibleWidth` is measured from the actual laid-out
                    // background, so clipping to it is exact whatever the
                    // container proposed. Zero until the first measurement
                    // lands, and `isScrolling` cannot be true before then —
                    // `overflow` needs both widths.
                    scrollingLabel
                        .frame(width: visibleWidth, alignment: .leading)
                        .clipped()
                }
            }
            // Kept as well: it bounds the static label's own truncation, and
            // costs nothing now that the overlay contains itself.
            .clipped()
            // **Neither background may answer a click.** The measuring label
            // is laid out at its *intrinsic* width — wider than the column, by
            // design, since that is how the overflow is known — and a
            // background takes part in hit testing. So an invisible copy of the
            // title extended past the name column and swallowed clicks meant
            // for the row underneath it, which is why rows were hard to select
            // and why the dead zone moved with the length of the name.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: VisibleWidthKey.self, value: proxy.size.width)
                }
                .allowsHitTesting(false)
            }
            .background(alignment: .leading) {
                measuringLabel.allowsHitTesting(false)
            }
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            // **The whole thing is inert, not just the parts that were
            // suspected.** Three passes chased this one hit test: the
            // measuring label's background, then the action cluster's reserved
            // frame, then the row's exclusive tap gesture. Each was real and
            // each recovered a *part* of the row — and clicking the name still
            // did nothing, because the name is the one thing in the row that
            // is always there, always wide, and made of a control (`Text`)
            // that answers a click on macOS whether or not it has anything to
            // do with one.
            //
            // A release name is a label. Nothing in it is clickable, selection
            // belongs to the enclosing `List`, and the row behind this already
            // carries the `contentShape` that catches the click. So it stops
            // taking part in hit testing entirely and the row gets every
            // event, including the ones that land on the title.
            .allowsHitTesting(false)
            .accessibilityLabel(text)
    }

    /// What the row is measured by, always.
    private var staticLabel: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            // **Tail, not middle.** Middle truncation was chosen when the name
            // shared its column with four quality chips and had perhaps half a
            // line: keeping both ends was the best of a bad set of options. The
            // name has the whole column now, so the beginning is almost always
            // enough to tell two releases apart, and an ellipsis in the middle
            // of a title reads as damage rather than as an aside. What falls
            // off the end is revealed by selecting the row.
            .truncationMode(.tail)
    }

    /// What moves. Drawn over the static label, never measured with it.
    private var scrollingLabel: some View {
        // Keyframes rather than `repeatForever(autoreverses:)`, which cannot
        // hold still: without the two dwells the name is in permanent motion
        // and never legible at either end.
        KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { offset in
            label.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0, duration: Self.dwell)
                LinearKeyframe(-overflow, duration: travel)
                LinearKeyframe(-overflow, duration: Self.dwell)
                // **A cut, not a return trip.** Scrolling back was motion
                // carrying no information — the name has already been read —
                // and reading it backwards at speed is the part that looked
                // busy. Snapping to the start and holding there for the same
                // dwell as the first pass makes the loop read as "here it is
                // again from the top" rather than as a shuttle.
                //
                // A hair above zero rather than zero: a keyframe with no
                // duration is not a jump, it is a keyframe the animator can
                // skip, and the track then loops from wherever it stopped.
                LinearKeyframe(0, duration: 0.001)
            }
        }
        // It must not answer hit tests: the row underneath is the thing being
        // clicked, and a moving label swallowing the click is a row that is
        // hard to select for reasons nobody can see.
        .allowsHitTesting(false)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Never drawn. Laid out at its intrinsic width purely so the width can be
    /// read back — which is the only way to know both *whether* the name is
    /// truncated and *how far* it has to travel.
    private var measuringLabel: some View {
        label
            .hidden()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                }
            }
    }
}

private struct TextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct VisibleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
