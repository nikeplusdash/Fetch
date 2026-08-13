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
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole point: the intrinsic-width label above is wider than
            // this frame, and this is what stops it reaching its neighbours.
            .clipped()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: VisibleWidthKey.self, value: proxy.size.width)
                }
            }
            .background(alignment: .leading) { measuringLabel }
            .onPreferenceChange(VisibleWidthKey.self) { visibleWidth = $0 }
            .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
            .accessibilityLabel(text)
    }

    @ViewBuilder
    private var content: some View {
        if isScrolling {
            // Keyframes rather than `repeatForever(autoreverses:)`, which
            // cannot hold still: without the two dwells the name is in
            // permanent motion and never legible at either end.
            KeyframeAnimator(initialValue: CGFloat.zero, repeating: true) { offset in
                label.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: Self.dwell)
                    LinearKeyframe(-overflow, duration: travel)
                    LinearKeyframe(-overflow, duration: Self.dwell)
                    // Back faster than out. The return trip carries no
                    // information — it has already been read — and dawdling
                    // through it is the part that would feel slow.
                    LinearKeyframe(0, duration: travel * 0.45)
                }
            }
        } else {
            Text(text)
                .font(font)
                .lineLimit(1)
                // Middle, as before: a release name's ends carry the title and
                // the group, and its middle carries the part you can infer.
                .truncationMode(.middle)
        }
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
